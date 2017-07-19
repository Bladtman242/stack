{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ConstraintKinds #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | The monad used for the command-line executable @stack@.

module Stack.Types.StackT
  (StackM
  ,runStackT
  ,runStackTGlobal
  ,runInnerStackT
  ,logSticky
  ,logStickyDone)
  where

import           Stack.Prelude hiding (lift)
import qualified Data.ByteString.Char8 as S8
import           Data.Char
import           Data.List (stripPrefix)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.Text.Encoding.Error as T
import qualified Data.Text.IO as T
import           Data.Time
import           GHC.Foreign (withCString, peekCString)
import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax (lift)
import           Lens.Micro (to)
import           Stack.Types.Config (GlobalOpts (..), ColorWhen(..))
import           Stack.Types.Internal
import           System.Console.ANSI
import           System.FilePath
import           System.IO
import           System.Log.FastLogger

#ifndef MIN_VERSION_time
#define MIN_VERSION_time(x, y, z) 0
#endif
#if !MIN_VERSION_time(1, 5, 0)
import           System.Locale
#endif

-- | Constraint synonym for all of the common environment instances
type HasEnv r = (HasLogOptions r, HasTerminal r, HasReExec r, HasSticky r)

-- | Constraint synonym for constraints commonly satisifed by monads used in stack.
type StackM r m =
    (MonadReader r m, MonadUnliftIO m, MonadLoggerIO m, MonadThrow m, HasEnv r)

    {- FIXME
-- | Takes the configured log level into account.
instance MonadIO m => MonadLogger (StackT config m) where
    monadLoggerLog = stickyLoggerFunc

instance MonadIO m => MonadLoggerIO (StackT config m) where
    askLoggerIO = getStickyLoggerFunc
    -}

-- | Run a Stack action, using global options.
runStackTGlobal :: (MonadIO m)
                => config -> GlobalOpts -> StackT (Env config) m a -> m a
runStackTGlobal config GlobalOpts{..} =
   runStackT config globalLogLevel globalTimeInLog globalTerminal globalColorWhen (isJust globalReExecVersion)

runStackT :: (MonadIO m)
          => config -> LogLevel -> Bool -> Bool -> ColorWhen -> Bool -> StackT (Env config) m a -> m a
runStackT config logLevel useTime terminal colorWhen reExec m = do
    useColor <- case colorWhen of
        ColorNever -> return False
        ColorAlways -> return True
        ColorAuto -> liftIO $ hSupportsANSI stderr
    canUseUnicode <- liftIO getCanUseUnicode
    withSticky terminal $ \sticky -> runReaderT (unStackT m) Env
        { envConfig = config
        , envReExec = reExec
        , envLogOptions = LogOptions
            { logUseColor = useColor
            , logUseUnicode = canUseUnicode
            , logUseTime = useTime
            , logMinLevel = logLevel
            , logVerboseFormat = logLevel <= LevelDebug
            }
        , envTerminal = terminal
        , envSticky = sticky
        }

-- | Taken from GHC: determine if we should use Unicode syntax
getCanUseUnicode :: IO Bool
getCanUseUnicode = do
    let enc = localeEncoding
        str = "\x2018\x2019"
        test = withCString enc str $ \cstr -> do
            str' <- peekCString enc cstr
            return (str == str')
    test `catchIO` \_ -> return False

runInnerStackT :: (HasEnv r, MonadReader r m, MonadIO m)
               => config -> StackT (Env config) IO a -> m a
runInnerStackT config inner = do
    reExec <- view reExecL
    logOptions <- view logOptionsL
    terminal <- view terminalL
    sticky <- view stickyL
    liftIO $ runReaderT (unStackT inner) Env
        { envConfig = config
        , envReExec = reExec
        , envLogOptions = logOptions
        , envTerminal = terminal
        , envSticky = sticky
        }

--------------------------------------------------------------------------------
-- Logging functionality

instance HasLogFunc (Env config) where
  logFuncL = to $ \env -> stickyLoggerFuncImpl (view stickyL env) (view logOptionsL env)

stickyLoggerFuncImpl
    :: ToLogStr msg
    => Sticky -> LogOptions
    -> (Loc -> LogSource -> LogLevel -> msg -> IO ())
stickyLoggerFuncImpl (Sticky mref) lo loc src level msg =
    case mref of
        Nothing ->
            loggerFunc
                lo
                out
                loc
                src
                (case level of
                     LevelOther "sticky-done" -> LevelInfo
                     LevelOther "sticky" -> LevelInfo
                     _ -> level)
                msg
        Just ref -> modifyMVar_ ref $ \sticky -> do
            let backSpaceChar = '\8'
                repeating = S8.replicate (maybe 0 T.length sticky)
                clear = S8.hPutStr out
                    (repeating backSpaceChar <>
                     repeating ' ' <>
                     repeating backSpaceChar)

            -- Convert some GHC-generated Unicode characters as necessary
            let msgText
                    | logUseUnicode lo = msgTextRaw
                    | otherwise = T.map replaceUnicode msgTextRaw

            case level of
                LevelOther "sticky-done" -> do
                    clear
                    T.hPutStrLn out msgText
                    hFlush out
                    return Nothing
                LevelOther "sticky" -> do
                    clear
                    T.hPutStr out msgText
                    hFlush out
                    return (Just msgText)
                _
                    | level >= logMinLevel lo -> do
                        clear
                        loggerFunc lo out loc src level $ toLogStr msgText
                        case sticky of
                            Nothing ->
                                return Nothing
                            Just line -> do
                                T.hPutStr out line >> hFlush out
                                return sticky
                    | otherwise ->
                        return sticky
  where
    out = stderr
    msgTextRaw = T.decodeUtf8With T.lenientDecode msgBytes
    msgBytes = fromLogStr (toLogStr msg)

-- | Replace Unicode characters with non-Unicode equivalents
replaceUnicode :: Char -> Char
replaceUnicode '\x2018' = '`'
replaceUnicode '\x2019' = '\''
replaceUnicode c = c

-- | Logging function takes the log level into account.
loggerFunc :: ToLogStr msg
           => LogOptions -> Handle -> Loc -> Text -> LogLevel -> msg -> IO ()
loggerFunc lo outputChannel loc _src level msg =
   when (level >= logMinLevel lo)
        (liftIO (do out <- getOutput
                    T.hPutStrLn outputChannel out))
  where
    getOutput = do
      timestamp <- getTimestamp
      l <- getLevel
      lc <- getLoc
      return $ T.concat
        [ T.pack timestamp
        , T.pack l
        , T.pack (ansi [Reset])
        , T.decodeUtf8 (fromLogStr (toLogStr msg))
        , T.pack lc
        , T.pack (ansi [Reset])
        ]
     where
       ansi xs | logUseColor lo = setSGRCode xs
               | otherwise = ""
       getTimestamp
         | logVerboseFormat lo && logUseTime lo =
           do now <- getZonedTime
              return $
                  ansi [SetColor Foreground Vivid Black]
                  ++ formatTime' now ++ ": "
         | otherwise = return ""
         where
           formatTime' =
               take timestampLength . formatTime defaultTimeLocale "%F %T.%q"
       getLevel
         | logVerboseFormat lo =
           return ((case level of
                      LevelDebug -> ansi [SetColor Foreground Dull Green]
                      LevelInfo -> ansi [SetColor Foreground Dull Blue]
                      LevelWarn -> ansi [SetColor Foreground Dull Yellow]
                      LevelError -> ansi [SetColor Foreground Dull Red]
                      LevelOther _ -> ansi [SetColor Foreground Dull Magenta]) ++
                   "[" ++
                   map toLower (drop 5 (show level)) ++
                   "] ")
         | otherwise = return ""
       getLoc
         | logVerboseFormat lo =
           return $
               ansi [SetColor Foreground Vivid Black] ++
               "\n@(" ++ fileLocStr ++ ")"
         | otherwise = return ""
       fileLocStr =
         fromMaybe file (stripPrefix dirRoot file) ++
         ':' :
         line loc ++
         ':' :
         char loc
         where
           file = loc_filename loc
           line = show . fst . loc_start
           char = show . snd . loc_start
       dirRoot = $(lift . T.unpack . fromMaybe undefined . T.stripSuffix (T.pack $ "Stack" </> "Types" </> "StackT.hs") . T.pack . loc_filename =<< location)

-- | The length of a timestamp in the format "YYYY-MM-DD hh:mm:ss.μμμμμμ".
-- This definition is top-level in order to avoid multiple reevaluation at runtime.
timestampLength :: Int
timestampLength =
  length (formatTime defaultTimeLocale "%F %T.000000" (UTCTime (ModifiedJulianDay 0) 0))

-- | With a sticky state, do the thing.
withSticky :: (MonadIO m)
           => Bool -> (Sticky -> m b) -> m b
withSticky terminal m =
    if terminal
       then do state <- liftIO (newMVar Nothing)
               originalMode <- liftIO (hGetBuffering stdout)
               liftIO (hSetBuffering stdout NoBuffering)
               a <- m (Sticky (Just state))
               state' <- liftIO (takeMVar state)
               liftIO (when (isJust state') (S8.putStr "\n"))
               liftIO (hSetBuffering stdout originalMode)
               return a
       else m (Sticky Nothing)

-- | Write a "sticky" line to the terminal. Any subsequent lines will
-- overwrite this one, and that same line will be repeated below
-- again. In other words, the line sticks at the bottom of the output
-- forever. Running this function again will replace the sticky line
-- with a new sticky line. When you want to get rid of the sticky
-- line, run 'logStickyDone'.
--
logSticky :: Q Exp
logSticky =
    logOther "sticky"

-- | This will print out the given message with a newline and disable
-- any further stickiness of the line until a new call to 'logSticky'
-- happens.
--
-- It might be better at some point to have a 'runSticky' function
-- that encompasses the logSticky->logStickyDone pairing.
logStickyDone :: Q Exp
logStickyDone =
    logOther "sticky-done"
