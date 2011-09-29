{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE OverloadedStrings #-}

module Snap.Snaplet.Auth.Backends.JsonFile 
  ( initJsonFileAuthManager
  , mkJsonAuthMgr
  ) where


import           Control.Applicative
import           Control.Monad.CatchIO (throw)
import           Control.Monad.State
import           Control.Concurrent.STM
import           Data.Aeson
import qualified Data.Attoparsec as Atto
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString as B
import qualified Data.Map as HM
import           Data.Map (Map)
import           Data.Maybe (isNothing, fromJust, isJust)
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Lens.Lazy
import           Data.Time
import           Web.ClientSession
import           System.Directory

import           Snap.Snaplet
import           Snap.Snaplet.Auth.Types
import           Snap.Snaplet.Auth.AuthManager hiding (createUser)
import           Snap.Snaplet.Session



------------------------------------------------------------------------------
-- | Initialize a JSON file backed 'AuthManager'
initJsonFileAuthManager 
  :: AuthSettings
  -- ^ Authentication settings for your app
  -> Lens b (Snaplet SessionManager)
  -- ^ Lens into a 'SessionManager' auth snaplet will use
  -> FilePath
  -- ^ Where to store user data as JSON
  -> SnapletInit b (AuthManager b)
initJsonFileAuthManager s l db = 
  makeSnaplet "JsonFileAuthManager" 
              "A snaplet providing user authentication using a JSON-file backend"
              Nothing $ liftIO $ do
    key <- getKey (asSiteKey s)
    jsonMgr <- mkJsonAuthMgr db
    return $ AuthManager {
    	  backend = jsonMgr
    	, session = l
    	, activeUser = Nothing
    	, minPasswdLen = asMinPasswdLen s
    	, rememberCookieName = asRememberCookieName s
    	, rememberPeriod = asRememberPeriod s
    	, siteKey = key
    	, lockout = asLockout s 
    }


------------------------------------------------------------------------------
-- | Load/create a datafile into memory cache and return the manager.
--
-- This data type can be used by itself for batch/non-handler processing.
mkJsonAuthMgr :: FilePath -> IO JsonFileAuthManager
mkJsonAuthMgr fp = do
  db <- loadUserCache fp
  let db' = case db of
              Left e -> error e
              Right x -> x
  cache <- newTVarIO db'
  return $ JsonFileAuthManager {
      memcache = cache
    , dbfile = fp
  }


type UserIdCache = Map UserId AuthUser


instance ToJSON UserIdCache where
  toJSON m = toJSON $ HM.toList m


instance FromJSON UserIdCache where
  parseJSON = fmap HM.fromList . parseJSON


type LoginUserCache = Map Text UserId


type RemTokenUserCache = Map Text UserId


-- JSON user back-end stores the user data and indexes for login and token
-- based logins.
data UserCache = UserCache {
	  uidCache    :: UserIdCache          -- the actual datastore
	, loginCache  :: LoginUserCache       -- fast lookup for login field
	, tokenCache  :: RemTokenUserCache    -- fast lookup for remember tokens
	, uidCounter  :: Int                  -- user id counter
}


defUserCache = UserCache {
	  uidCache = HM.empty
	, loginCache = HM.empty
	, tokenCache = HM.empty
	, uidCounter = 0
}


loadUserCache :: FilePath -> IO (Either String UserCache)
loadUserCache fp = do
  chk <- doesFileExist fp
  case chk of
    True -> do
      d <- B.readFile fp
      case Atto.parseOnly json d of
        Left e -> return . Left $ "Can't open JSON auth backend. Error: " ++ e
        Right v -> case fromJSON v of
          Error e -> return . Left $ "Malformed JSON auth data store. Error: " ++ e
          Success db -> return $ Right db
    False -> do
      putStrLn "User JSON datafile not found. Creating a new one."
      return $ Right defUserCache


data JsonFileAuthManager = JsonFileAuthManager {
	  memcache :: TVar UserCache
	, dbfile :: FilePath
}


instance IAuthBackend JsonFileAuthManager where

  save mgr u = do
    now <- getCurrentTime
    oldByLogin <- lookupByLogin mgr (userLogin u)
    oldById <- case userId u of
      Nothing -> return Nothing
      Just x -> lookupByUserId mgr x
    res <- atomically $ do
      cache <- readTVar (memcache mgr)
      res <- case userId u of
        Nothing -> create cache now oldByLogin
        Just _ -> update cache now oldById
      case res of
        Left e -> return $ Left e
        Right (cache', u') -> do
          writeTVar (memcache mgr) cache'
          return $ Right (cache', u')
    case res of
      Left e -> throw e
      Right (cache', u') -> do
        dumpToDisk cache'
        return u'
    where
      create 
        :: UserCache 
        -> UTCTime 
        -> (Maybe AuthUser) 
        -> STM (Either BackendError (UserCache, AuthUser))
      create cache now old = do
        case old of
          Just _ -> return $ Left DuplicateLogin
          Nothing -> do
            new <- do
              let uid' = UserId . showT $ uidCounter cache + 1
              let u' = u { userUpdatedAt = Just now, userId = Just uid' }
              return $ cache {
              	uidCache = HM.insert uid' u' $ uidCache cache
              , loginCache = HM.insert (userLogin u') uid' $ loginCache cache
              , tokenCache = case userRememberToken u' of
                                Nothing -> tokenCache cache
                                Just x -> HM.insert x uid' $ tokenCache cache
              , uidCounter = uidCounter cache + 1
              }
            return $ Right (new, getLastUser new)


      -- lookup old record, see what's changed and update indexes accordingly
      update 
        :: UserCache 
        -> UTCTime 
        -> (Maybe AuthUser) 
        -> STM (Either BackendError (UserCache, AuthUser))
      update cache now old = 
        case old of
          Nothing -> return $ Left (BackendError "User not found; should never happen")
          Just x -> do
            let oldLogin = userLogin x
            let oldToken = userRememberToken x
            let uid = fromJust $ userId u
            let newLogin = userLogin u
            let newToken = userRememberToken u
            let lc = if oldLogin /= userLogin u 
                      then HM.insert newLogin uid . HM.delete oldLogin $ loginCache cache
                      else loginCache cache
            let tc = if oldToken /= newToken && isJust oldToken
                      then HM.delete (fromJust oldToken) $ loginCache cache
                      else tokenCache cache
            let tc' = case newToken of 
                        Just t -> HM.insert t uid tc
                        Nothing -> tc
            let u' = u { userUpdatedAt = Just now }
            let new = cache {
                          uidCache = HM.insert uid u' $ uidCache cache
                        , loginCache = lc
                        , tokenCache = tc'
                      }
            return $ Right (new, u')

      -- Sync user database to disk
      -- Need to implement a mutex here; simult syncs could screw things up
      dumpToDisk c = LB.writeFile (dbfile mgr) (encode c)

      -- Get's the last added user
      getLastUser cache = maybe e id $ getUser cache uid
        where uid = UserId . showT $ uidCounter cache
              e = error "getLastUser failed. This should not happen."


  destroy = error "JsonFile: destroy is not yet implemented"

  lookupByUserId mgr uid = withCache mgr f
    where f cache = getUser cache uid

  lookupByLogin mgr login = withCache mgr f
    where 
      f cache = getUid >>= getUser cache
        where getUid = HM.lookup login (loginCache cache)
              
  lookupByRememberToken mgr token = withCache mgr f
    where
      f cache = getUid >>= getUser cache
        where getUid = HM.lookup token (tokenCache cache)


withCache mgr f = atomically $ do
  cache <- readTVar $ memcache mgr
  return $ f cache


getUser cache uid = HM.lookup uid (uidCache cache)


------------------------------------------------------------------------------
-- JSON Instances
--
------------------------------------------------------------------------------


instance ToJSON UserCache where
  toJSON uc = object 
    [ "uidCache" .= uidCache uc
    , "loginCache" .= loginCache uc
    , "tokenCache" .= tokenCache uc 
    , "uidCounter" .= uidCounter uc]


instance FromJSON UserCache where
  parseJSON (Object v) = 
    UserCache
      <$> v .: "uidCache"
      <*> v .: "loginCache"
      <*> v .: "tokenCache"
      <*> v .: "uidCounter"


instance ToJSON AuthUser where
  toJSON u = object
    [ "uid" .= userId u
    , "login" .= userLogin u
    , "pw" .= userPassword u
    , "activated_at" .= userActivatedAt u
    , "suspended_at" .= userSuspendedAt u
    , "remember_token" .= userRememberToken u
    , "login_count" .= userLoginCount u
    , "failed_login_count" .= userFailedLoginCount u
    , "locked_until" .= userLockedOutUntil u
    , "current_login_at" .= userCurrentLoginAt u
    , "last_login_at" .= userLastLoginAt u
    , "current_ip" .= userCurrentLoginIp u
    , "last_ip" .= userLastLoginIp u
    , "created_at" .= userCreatedAt u
    , "updated_at" .= userUpdatedAt u
    , "meta" .= userMeta u ]


instance FromJSON AuthUser where
  parseJSON (Object v) = AuthUser
    <$> v .: "uid"
    <*> v .: "login"
    <*> v .: "pw"
    <*> v .: "activated_at"
    <*> v .: "suspended_at"
    <*> v .: "remember_token"
    <*> v .: "login_count"
    <*> v .: "failed_login_count"
    <*> v .: "locked_until"
    <*> v .: "current_login_at"
    <*> v .: "last_login_at"
    <*> v .: "current_ip"
    <*> v .: "last_ip"
    <*> v .: "created_at"
    <*> v .: "updated_at"
    <*> return []
    <*> v .: "meta"


instance ToJSON Password where
  toJSON (ClearText _) = error "ClearText passwords can't be serialized into JSON"
  toJSON (Encrypted x) = toJSON x


instance FromJSON Password where
  parseJSON = fmap Encrypted . parseJSON
  

showT = T.pack . show