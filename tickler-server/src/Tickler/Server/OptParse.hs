{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Tickler.Server.OptParse
    ( module Tickler.Server.OptParse
    , module Tickler.Server.OptParse.Types
    ) where

import Import

import qualified Data.Text as T
import Text.Read

import System.Environment (getArgs, getEnvironment, lookupEnv)

import Control.Monad.Trans.AWS as AWS
import Database.Persist.Sqlite

import Options.Applicative

import Tickler.API
import Tickler.Server.OptParse.Types

getInstructions :: IO Instructions
getInstructions = do
    Arguments cmd flags <- getArguments
    config <- getConfiguration cmd flags
    env <- getEnv
    combineToInstructions cmd flags config env

combineToInstructions ::
       Command -> Flags -> Configuration -> Environment -> IO Instructions
combineToInstructions (CommandServe ServeFlags {..}) Flags Configuration Environment {..} = do
    let serveSetPort = fromMaybe 8001 $ serveFlagPort `mplus` envPort
    webHost <-
        case serveFlagWebHost `mplus` envWebHost of
            Nothing -> die "No web host configured."
            Just wh -> pure $ T.pack wh
    dbPath <- resolveFile' $ fromMaybe "tickler.db" $ serveFlagDb <> envDb
    let serveSetConnectionInfo =
            mkSqliteConnectionInfo $ T.pack $ fromAbsFile dbPath
    let serveSetConnectionCount = fromMaybe 4 serveFlagConnectionCount
    serveSetAdmins <-
        forM serveFlagAdmins $ \s ->
            case parseUsername $ T.pack s of
                Nothing -> die $ unwords ["Invalid admin username:", s]
                Just u -> pure u
    let LooperFlags {..} = serveFlagsLooperFlags
    let LoopersEnvironment {..} = envLoopersEnvironment
    let defaultLoopersEnabled =
            fromMaybe True $
            looperFlagDefaultEnabled `mplus` looperEnvDefaultEnabled
    let defaultLoopersPeriod =
            fromMaybe 60 $
            looperFlagDefaultPeriod `mplus` looperEnvDefaultPeriod
    let defaultLooperRetryDelay =
            fromMaybe 1000000 $
            looperFlagDefaultRetryDelay `mplus` looperEnvDefaultRetryDelay
    let defaultLooperRetryAmount =
            fromMaybe 7 $
            looperFlagDefaultRetryTimes `mplus` looperEnvDefaultRetryTimes
    let looperSetConnectionInfo = serveSetConnectionInfo
    let looperSetConnectionCount = serveSetConnectionCount
    let combineToLooperSets ::
               LooperFlagsWith a
            -> LooperEnvWith b
            -> (a -> b -> IO c)
            -> IO (LooperSetsWith c)
        combineToLooperSets LooperFlagsWith {..} LooperEnvWith {..} func = do
            let enabled =
                    fromMaybe defaultLoopersEnabled $
                    looperFlagEnable `mplus` looperEnvEnable
            if enabled
                then do
                    let LooperFlagsRetryPolicy {..} = looperFlagsRetryPolicy
                    let LooperEnvRetryPolicy {..} = looperEnvRetryPolicy
                    let static =
                            LooperStaticConfig
                                { looperStaticConfigPeriod =
                                      fromMaybe defaultLoopersPeriod $
                                      looperFlagsPeriod `mplus` looperEnvPeriod
                                , looperStaticConfigRetryPolicy =
                                      LooperRetryPolicy
                                          { looperRetryPolicyDelay =
                                                fromMaybe
                                                    defaultLooperRetryDelay $
                                                looperFlagsRetryDelay `mplus`
                                                looperEnvRetryDelay
                                          , looperRetryPolicyAmount =
                                                fromMaybe
                                                    defaultLooperRetryAmount $
                                                looperFlagsRetryAmount `mplus`
                                                looperEnvRetryAmount
                                          }
                                }
                    LooperEnabled static <$> func looperFlags looperEnv
                else pure LooperDisabled
    looperSetTriggererSets <-
        combineToLooperSets looperFlagTriggererFlags looperEnvTriggererEnv $
        const $ const $ pure TriggererSettings
    looperSetEmailerSets <-
        combineToLooperSets looperFlagEmailerFlags looperEnvEmailerEnv $
        const $ const $ pure $ EmailerSettings Discover
    looperSetTriggeredIntrayItemSchedulerSets <-
        combineToLooperSets
            looperFlagTriggeredIntrayItemSchedulerFlags
            looperEnvTriggeredIntrayItemSchedulerEnv $
        const $ const $ pure ()
    looperSetTriggeredIntrayItemSenderSets <-
        combineToLooperSets
            looperFlagTriggeredIntrayItemSenderFlags
            looperEnvTriggeredIntrayItemSenderEnv $
        const $ const $ pure ()
    looperSetVerificationEmailConverterSets <-
        combineToLooperSets
            looperFlagVerificationEmailConverterFlags
            looperEnvVerificationEmailConverterEnv $ \() () -> do
            pure
                VerificationEmailConverterSettings
                    { verificationEmailConverterSetFromAddress -- TODO make these configurable
                       = unsafeEmailAddress "verification" "tickler.cs-syd.eu"
                    , verificationEmailConverterSetFromName = "Tickler"
                    , verificationEmailConverterSetWebHost = webHost
                    }
    looperSetTriggeredEmailSchedulerSets <-
        combineToLooperSets
            looperFlagTriggeredEmailSchedulerFlags
            looperEnvTriggeredEmailSchedulerEnv $
        const $ const $ pure ()
    looperSetTriggeredEmailConverterSets <-
        combineToLooperSets
            looperFlagTriggeredEmailConverterFlags
            looperEnvTriggeredEmailConverterEnv $ \() () -> do
            pure
                TriggeredEmailConverterSettings
                    { triggeredEmailConverterSetFromAddress -- TODO make these configurable
                       = unsafeEmailAddress "triggered" "tickler.cs-syd.eu"
                    , triggeredEmailConverterSetFromName = "Tickler"
                    , triggeredEmailConverterSetWebHost = webHost
                    }
    let serveSetLooperSettings = LooperSettings {..}
    pure $ Instructions (DispatchServe ServeSettings {..}) Settings

getConfiguration :: Command -> Flags -> IO Configuration
getConfiguration _ _ = pure Configuration

getEnv :: IO Environment
getEnv = do
    env <- getEnvironment
    envDb <- lookupEnv "DATABASE"
    envWebHost <- lookupEnv "WEB_HOST"
    envPort <- maybeReadEnv "API_PORT" env
    envLoopersEnvironment <- getLoopersEnv
    pure Environment {..}

getLoopersEnv :: IO LoopersEnvironment
getLoopersEnv = do
    env <- getEnvironment
    looperEnvDefaultEnabled <- maybeReadEnv "LOOPERS_DEFAULT_ENABLED" env
    looperEnvDefaultPeriod <- maybeReadEnv "LOOPERS_DEFAULT_PERIOD" env
    looperEnvDefaultRetryDelay <- maybeReadEnv "LOOPERS_DEFAULT_RETRY_DELAY" env
    looperEnvDefaultRetryTimes <-
        maybeReadEnv "LOOPERS_DEFAULT_RETRY_AMOUNT" env
    looperEnvTriggererEnv <- getLooperEnvWith "TRIGGERER" $ pure ()
    looperEnvEmailerEnv <- getLooperEnvWith "EMAILER" $ pure ()
    looperEnvTriggeredIntrayItemSchedulerEnv <-
        getLooperEnvWith "TRIGGERED_INTRAY_ITEM_SCHEDULER" $ pure ()
    looperEnvTriggeredIntrayItemSenderEnv <-
        getLooperEnvWith "TRIGGERED_INTRAY_ITEM_SENDER" $ pure ()
    looperEnvVerificationEmailConverterEnv <-
        getLooperEnvWith "VERIFICATION_EMAIL_CONVERTER" $ pure ()
    looperEnvTriggeredEmailSchedulerEnv <-
        getLooperEnvWith "TRIGGERED_EMAIL_SCHEDULER" $ pure ()
    looperEnvTriggeredEmailConverterEnv <-
        getLooperEnvWith "TRIGGERED_EMAIL_CONVERTER" $ pure ()
    pure LoopersEnvironment {..}

getLooperEnvWith :: String -> IO a -> IO (LooperEnvWith a)
getLooperEnvWith name func = do
    env <- getEnvironment
    looperEnvEnable <-
        maybeReadEnv (intercalate "_" ["LOOPER", name, "ENABLED"]) env
    looperEnvPeriod <-
        maybeReadEnv (intercalate "_" ["LOOPER", name, "PERIOD"]) env
    looperEnvRetryPolicy <- getLooperRetryPolicyEnv name
    looperEnv <- func
    pure LooperEnvWith {..}

getLooperRetryPolicyEnv :: String -> IO LooperEnvRetryPolicy
getLooperRetryPolicyEnv name = do
    env <- getEnvironment
    looperEnvRetryDelay <-
        maybeReadEnv (intercalate "_" ["LOOPER", name, "RETRY", "DELAY"]) env
    looperEnvRetryAmount <-
        maybeReadEnv (intercalate "_" ["LOOPER", name, "RETRY", "AMOUNT"]) env
    pure LooperEnvRetryPolicy {..}

eitherParseEnv ::
       Show a
    => String
    -> (a -> Either String b)
    -> [(String, a)]
    -> IO (Maybe b)
eitherParseEnv k func env =
    forM (lookup k env) $ \s ->
        case func s of
            Left e ->
                die $
                unwords
                    [ "Unable to read ENV Var:"
                    , k
                    , "which has value:"
                    , show s
                    , "with error:"
                    , e
                    ]
            Right v -> pure v

maybeParseEnv ::
       Show a => [Char] -> (a -> Maybe b) -> [(String, a)] -> IO (Maybe b)
maybeParseEnv k func =
    eitherParseEnv k $ \s ->
        case func s of
            Nothing -> Left "Parsing failed without a good error message."
            Just v -> Right v

maybeReadEnv :: Read b => String -> [(String, String)] -> IO (Maybe b)
maybeReadEnv k = maybeParseEnv k readMaybe

getArguments :: IO Arguments
getArguments = do
    args <- getArgs
    let result = runArgumentsParser args
    handleParseResult result

runArgumentsParser :: [String] -> ParserResult Arguments
runArgumentsParser = execParserPure prefs_ argParser
  where
    prefs_ =
        ParserPrefs
            { prefMultiSuffix = ""
            , prefDisambiguate = True
            , prefShowHelpOnError = True
            , prefShowHelpOnEmpty = True
            , prefBacktrack = True
            , prefColumns = 80
            }

argParser :: ParserInfo Arguments
argParser = info (helper <*> parseArgs) help_
  where
    help_ = fullDesc <> progDesc description
    description = "Tickler server"

parseArgs :: Parser Arguments
parseArgs = Arguments <$> parseCommand <*> parseFlags

parseCommand :: Parser Command
parseCommand = hsubparser $ mconcat [command "serve" parseCommandServe]

parseCommandServe :: ParserInfo Command
parseCommandServe = info parser modifier
  where
    parser = CommandServe <$> parseServeFlags
    modifier = fullDesc <> progDesc "Command example."

parseServeFlags :: Parser ServeFlags
parseServeFlags =
    ServeFlags <$>
    option
        (Just <$> auto)
        (mconcat
             [ long "web-host"
             , value Nothing
             , metavar "HOST"
             , help "the host to serve the web server on"
             ]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long "api-port"
             , value Nothing
             , metavar "PORT"
             , help "the port to serve the API on"
             ]) <*>
    option
        (Just <$> str)
        (mconcat
             [ long "database"
             , value Nothing
             , metavar "DATABASE_CONNECTION_STRING"
             , help "The sqlite connection string"
             ]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long "connection-count"
             , value Nothing
             , metavar "CONNECTION_COUNT"
             , help "the number of database connections to use"
             ]) <*>
    many
        (strOption
             (mconcat [long "admin", metavar "USERNAME", help "An admin to use"])) <*>
    parseLooperFlags

parseLooperFlags :: Parser LooperFlags
parseLooperFlags =
    LooperFlags <$>
    onOffFlag
        "loopers"
        (help $ unwords ["enable or disable all the loopers by default"]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long "default-period"
             , value Nothing
             , metavar "SECONDS"
             , help "The default period for all loopers"
             ]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long "default-retry-delay"
             , value Nothing
             , metavar "MICROSECONDS"
             , help "The retry delay for all loopers, in microseconds"
             ]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long "default-retry-amount"
             , value Nothing
             , metavar "AMOUNT"
             , help
                   "The default amount of times to retry a looper before failing"
             ]) <*>
    parseLooperFlagsWith "triggerer" (pure ()) <*>
    parseLooperFlagsWith "emailer" (pure ()) <*>
    parseLooperFlagsWith "intray-item-scheduler" (pure ()) <*>
    parseLooperFlagsWith "intray-item-sender" (pure ()) <*>
    parseLooperFlagsWith "verification-email-converter" (pure ()) <*>
    parseLooperFlagsWith "triggered-email-scheduler" (pure ()) <*>
    parseLooperFlagsWith "triggered-email-converter" (pure ())

parseLooperFlagsWith :: String -> Parser a -> Parser (LooperFlagsWith a)
parseLooperFlagsWith name func =
    LooperFlagsWith <$>
    onOffFlag
        (intercalate "-" [name, "looper"])
        (mconcat [help $ unwords ["enable or disable the", name, "looper"]]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long $ intercalate "-" [name, "period"]
             , value Nothing
             , metavar "SECONDS"
             , help $ unwords ["The period for", name]
             ]) <*>
    parseLooperRetryPolicyFlags name <*>
    func

parseLooperRetryPolicyFlags :: String -> Parser LooperFlagsRetryPolicy
parseLooperRetryPolicyFlags name =
    LooperFlagsRetryPolicy <$>
    option
        (Just <$> auto)
        (mconcat
             [ long $ intercalate "-" [name, "retry-delay"]
             , value Nothing
             , metavar "MICROSECONDS"
             , help $ unwords ["The retry delay for", name]
             ]) <*>
    option
        (Just <$> auto)
        (mconcat
             [ long $ intercalate "-" [name, "retry-amount"]
             , value Nothing
             , metavar "AMOUNT"
             , help $ unwords ["The amount of times to retry for", name]
             ])

onOffFlag :: String -> Mod FlagFields (Maybe Bool) -> Parser (Maybe Bool)
onOffFlag suffix mods =
    flag' (Just True) (mconcat [long $ pf "enable", hidden]) <|>
    flag' (Just False) (mconcat [long $ pf "disable", hidden]) <|>
    flag' Nothing (mconcat [long ("(enable|disable)-" ++ suffix), mods]) <|>
    pure Nothing
  where
    pf s = intercalate "-" [s, suffix]

parseFlags :: Parser Flags
parseFlags = pure Flags
