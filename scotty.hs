{-# LANGUAGE OverloadedStrings #-}

import           Blaze.ByteString.Builder (toLazyByteString)
import           Control.Monad (liftM, join, forM_)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Logger (runStderrLoggingT)
import qualified Crypto.PubKey.RSA as RSA
import           Data.Aeson hiding (json)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Char8 as B
import qualified Data.ByteString.Lazy as BL
import           Data.Int (Int64)
import           Data.List ((\\))
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Text.Lazy (Text)
import qualified Data.Text.Lazy as L
import qualified Data.Text as T
import           Data.Text.Read (decimal)
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Lazy.Encoding as LE
import           Data.Time.Clock.POSIX
import           Database.Persist.Sql (runSqlPool, runMigration, runSqlPersistMPool)
import           Database.Persist.Sqlite (createSqlitePool)
import           Network.HTTP.Types
import qualified Network.Wai as W
import qualified Text.Blaze.Html5 as H
import           Text.Blaze.Html5.Attributes hiding (scope)
import           Text.Blaze.Html.Renderer.Text (renderHtml)
import qualified Web.ClientSession as CS
import           Web.Cookie
import           Web.Scotty

import           Broch.Model
import           Broch.OAuth2.Authorize
import           Broch.OAuth2.Token
import qualified Broch.Persist as BP
import           Broch.Random
import           Broch.Token
import           Broch.TestApp (testClients)

main :: IO ()
main = do
    -- Back end storage
    pool <- createSqlitePool "broch.db3" 1
    runStderrLoggingT $ runSqlPool (runMigration BP.migrateAll) pool
    mapM_ (\c -> runSqlPersistMPool (BP.createClient c) pool) testClients
    -- Create the cookie encryption key
    csKey <- CS.getDefaultKey
    -- Create everything we need for the oauth endpoints
    -- First we need an RSA key for signing tokens
    (_, kPr) <- withCPRG $ \g -> RSA.generate g 64 65537

    let runDB = flip runSqlPersistMPool pool
    let getClient = runDB . BP.getClientById
    let createAuthorization code uid clnt now scp uri = runDB $
                            BP.createAuthorization code uid clnt now scp uri

    let getAuthorization = runDB . BP.getAuthorizationByCode
    let authenticateResourceOwner username password
            | username == password = return $ Just username
            | otherwise            = return Nothing
    let createAccessToken = createJwtAccessToken $ RSA.private_pub kPr
    let decodeRefreshToken _ jwt = return $ decodeJwtRefreshToken kPr (TE.encodeUtf8 jwt)
    let getApproval uid clnt now = runDB $ BP.getApproval uid (clientId clnt) now
    let saveApproval (Approval uid cid scopes expiry) = runDB $ BP.createApproval uid cid scopes (posixSecondsToUTCTime expiry)

    scotty 3000 $ do
        get "/" $ text "Hello"

        get "/oauth/authorize" $ do
            request >>= debug . W.rawQueryString

            user <- getAuthId csKey
            env  <- fmap toMap params
            curi <- liftIO $ getClientAndRedirectURI getClient env
            case curi of
                -- Report a "bad client" error to the user without a redirect
                Left err             -> status badRequest400 >> text (L.pack $ show err)
                Right (client, mURI) -> do
                    let redirectURI = fromMaybe (defaultRedirectURI client) mURI
                    -- From this point, all errors can be safely returned to the client
                    maybeState   <- either (errorResponse redirectURI Nothing) return $ getState env
                    (responseType, requestedScope) <- either (errorResponse redirectURI maybeState) return $ getGrantData env user client
                    now   <- liftIO getPOSIXTime
                    -- The scope approved by the user
                    scope <- resourceOwnerApproval csKey getApproval user client requestedScope now

                    case responseType of
                        Code  -> do
                                  code <- liftIO generateCode
                                  liftIO $ createAuthorization (TE.decodeUtf8 code) user client now scope mURI
                                  authzCodeResponse redirectURI maybeState code scope
                        Token -> status forbidden403 >> text "Implicit grant not supported"
                        _     -> status forbidden403 >> text "Response type not (yet) supported"

        post "/oauth/token" $ do
            client <- basicAuthClient getClient
            case client of
                Left (st, err) -> status st >> text err
                Right c        -> do
                    env  <- fmap toMap params
                    now  <- liftIO getPOSIXTime
                    resp <- liftIO $ processTokenRequest env c now getAuthorization authenticateResourceOwner createAccessToken decodeRefreshToken
                    case resp of
                        Left bad -> status badRequest400 >> json (toJSON bad)
                        Right tr -> json $ toJSON tr

        get "/login" $ do
            html $ renderHtml $ loginPage

        post "/login" $ do
            uid  <- param "username" :: ActionM T.Text
            pwd  <- param "password" :: ActionM T.Text
            liftIO $ B.putStrLn $ B.concat $ fmap TE.encodeUtf8 [uid, " ", pwd]
            user <- liftIO $ authenticateResourceOwner uid pwd
            liftIO $ putStrLn $ show user
            case user of
                Nothing -> redirect "/login"
                Just u  -> do
                    setEncryptedCookie csKey "bsid" (TE.encodeUtf8 u)
                    l <- getCachedLocation csKey "/uhoh"
                    -- This doesn't work. Overwrites uid cookie: clearCachedLocation
                    debug l
                    redirect l

        get "/approval" $ do
            user   <- getAuthId csKey
            now    <- liftIO getPOSIXTime
            Just client <- param "client_id" >>= liftIO . getClient
            scope  <- param "scope" >>= return . (L.splitOn " ")
            html $ renderHtml $ approvalPage client scope (round now)

        post "/approval" $ do
            user   <- getAuthId csKey
            clntId <- param "client_id"
            expiryTxt <- param "expiry"
            scope     <- param "scope"
            let Right (expiry, _) = decimal expiryTxt
            liftIO $ saveApproval $ Approval user clntId scope (fromIntegral (expiry :: Int64))
            l <- getCachedLocation csKey "/uhoh"
            clearCachedLocation
            redirect l

        get "/logout" $ logout


resourceOwnerApproval key getApproval uid client requestedScope now = do
    -- Try to load a previous approval
    maybeApproval <- liftIO $ getApproval uid client now
    case maybeApproval of
        -- TODO: Check scope overlap and allow asking for extra scope
        -- not previously granted
        Just (Approval _ _ scope _) -> return (scope \\ requestedScope)
        -- Nothing exists: Redirect to approval handler with scopes and client id
        Nothing -> do
            let query = renderSimpleQuery True [("client_id", TE.encodeUtf8 $ clientId client), ("scope", TE.encodeUtf8 $ T.intercalate " " requestedScope)]
            cacheLocation key
            redirect $ L.fromStrict $ TE.decodeUtf8 $ B.concat ["/approval", query]



-- | Reports an error to the client itself, via a redirect
-- errorResponse :: Text -> Maybe Text -> AuthorizationError -> HandlerT site IO a
errorResponse rURI mState e = redirect $ L.fromStrict $ authzErrorURL rURI mState e

authzCodeResponse rURI mState code scope = redirect $ L.fromStrict $ authzCodeResponseURL rURI mState code scope

debug :: (MonadIO m, Show a) => a -> m ()
debug = liftIO . putStrLn . show

loginPage = H.html $ do
    H.head $ do
      H.title "Login."
    H.body $ do
        H.form H.! method "post" H.! action "/login" $ do
            H.input H.! type_ "text" H.! name "username"
            H.input H.! type_ "password" H.! name "password"
            H.input H.! type_ "submit" H.! value "Login"

--approvalPage :: Client -> [Text] -> Int64 -> H.Html
approvalPage client scopes now = H.docTypeHtml $ H.html $ do
    H.head $ do
      H.title "Approvals"
    H.body $ do
        H.h2 $ "Authorization Approval Request"
        H.form H.! method "post" H.! action "/approval" $ do
            H.input H.! type_ "hidden" H.! name "client_id" H.! value (H.toValue (clientId client))
            H.label H.! for "expiry" $ "Expires after"
            H.select H.! name "expiry" $ do
                H.option H.! value (H.toValue oneDay) $ "One day"
                H.option H.! value (H.toValue oneWeek) $ "One week"
                H.option H.! value (H.toValue oneMonth) $ "30 days"
            forM_ scopes $ \s -> do
                H.input H.! type_ "checkBox" H.! name "scope" H.! value (H.toValue s)
                H.toHtml s
                H.br

            H.input H.! type_ "submit" H.! value "Approve"
  where
    aDay    = round posixDayLength :: Int64
    oneDay  = now + aDay
    oneWeek = now + 7*aDay
    oneMonth = now + 30*aDay


logout = clearCookie "bsid"

getAuthId :: CS.Key -> ActionM T.Text
getAuthId key = do
    uid <- getEncryptedCookie key "bsid"
    liftIO $ putStrLn $ show uid
    case uid of
        Just u  -> return (TE.decodeUtf8 u)
        Nothing -> cacheLocation key >> redirect "/login"

clearCachedLocation = clearCookie "loc"

cacheLocation key = do
    r <- request
    setEncryptedCookie key "loc" $ B.concat [W.rawPathInfo r, W.rawQueryString r]

getCachedLocation :: CS.Key -> Text -> ActionM Text
getCachedLocation key defaultUrl = getEncryptedCookie key "loc" >>=
                                      return . (maybe defaultUrl (L.fromStrict . TE.decodeUtf8))


makeCookie :: B.ByteString -> B.ByteString -> SetCookie
makeCookie n v = def { setCookieName = n, setCookieValue = v, setCookieHttpOnly = True, setCookiePath = Just "/" }

renderSetCookie' :: SetCookie -> Text
renderSetCookie' = LE.decodeUtf8 . toLazyByteString . renderSetCookie

getEncryptedCookie key n = getCookie n >>= return . join .fmap (CS.decrypt key)

setEncryptedCookie key n v = do
    v' <- liftIO $ CS.encryptIO key v
    setCookie n v'

setCookie :: B.ByteString -> B.ByteString -> ActionM ()
setCookie n v = setHeader "Set-Cookie" $ renderSetCookie' $ makeCookie n v

clearCookie n = setHeader "Set-Cookie" $ renderSetCookie' $ (makeCookie n "") { setCookieMaxAge = Just 0 }

getCookie :: B.ByteString -> ActionM (Maybe B.ByteString)
getCookie name = do
    cookies <- fmap (fmap (parseCookies . BL.toStrict . LE.encodeUtf8)) $ header "Cookie"
    case cookies of
        Nothing -> return Nothing
        Just cs -> return $ lookup name cs


toMap :: [(Text, Text)] -> Map.Map T.Text [T.Text]
toMap = Map.unionsWith (++) . map (\(x, y) -> Map.singleton (L.toStrict x) [(L.toStrict y)])

basicAuthClient :: (ClientId -> IO (Maybe Client)) -> ActionM (Either (Status, Text) Client)
basicAuthClient getClient = do
    r <- request
    case basicAuthCredentials r of
        Left  msg           -> return $ Left (unauthorized401, msg)
        Right (cid, secret) -> do
            client <- liftIO $ getClient cid
            return $ maybe (Left (forbidden403, "Authentication failed")) Right $ client >>= validateSecret secret

validateSecret :: T.Text -> Client -> Maybe Client
validateSecret secret client = clientSecret client >>= \s ->
                                  if secret == s
                                  then Just client
                                  else Nothing

-- | Extract the Basic authentication credentials from a WAI request.
-- Returns an error message if the header is missing or cannot be decoded.
basicAuthCredentials :: W.Request -> Either Text (T.Text, T.Text)
basicAuthCredentials r = do
    authzHdr <- maybe (Left "Authentication required") return $ lookup hAuthorization $ W.requestHeaders r
    maybe (Left "Invalid authorization header") return $ decodeHeader authzHdr
  where
    decodeHeader h = case B.split ' ' h of
                       ["Basic", b] -> either (const Nothing) creds $ B64.decode b
                       _            -> Nothing
    creds bs = case fmap (T.break (== ':')) $ TE.decodeUtf8' bs of
                 Left _       -> Nothing
                 Right (u, p) -> if T.length p == 0
                                 then Nothing
                                 else Just (u, T.tail p)

