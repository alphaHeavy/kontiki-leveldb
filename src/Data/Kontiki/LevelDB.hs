{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
module Data.Kontiki.LevelDB (
    initializeLog
  , readValue
  , runLevelDBLog
  , truncateLog
  , writeValue
  , LevelDBLog(..)
  , LevelDBLogType(..)
  , LevelDBMessage(..)
  , LevelDBOperationType(..)) where

import Control.Applicative
import Control.Concurrent.Forkable
import Control.Monad.Base
import Control.Monad.IO.Class
import Control.Monad.Reader (MonadReader, ReaderT, ask, runReaderT)
import Control.Monad.Trans
import Control.Monad.Trans.Resource
import Data.Binary
import Data.Binary.Put (runPut)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Functor.Identity
import Database.LevelDB (DB)
import qualified Database.LevelDB as LDB
import GHC.Generics
import Network.Kontiki.Raft hiding (truncateLog)
import System.FilePath

import Prelude hiding (log)

--LevelDB Layout
--  Your Data Table (your key,your value)
--    Your Value needs to be prefixed with the index and term
--  Transaction Index (index, your key)

data LevelDBLogType = LevelDBLogType DB DB

type LevelDBEntry = Entry LevelDBMessage

newtype LevelDBLog m r = LevelDBLog {unLevelDBLog :: ReaderT LevelDBLogType m r}
  deriving ( Applicative
           , Functor
           , Monad
           , MonadIO
           , MonadReader LevelDBLogType
           , MonadThrow
           , MonadTrans
           )

deriving instance MonadBase b m => MonadBase b (LevelDBLog m)

deriving instance MonadResource m => MonadResource (LevelDBLog m)

getEntryFromTable :: MonadResource m => LevelDBLogType -> ByteString -> m (Maybe LevelDBEntry)
getEntryFromTable (LevelDBLogType table _) tableKey = do
  mVal <- LDB.get table LDB.defaultReadOptions tableKey
  case mVal of
    Just val ->
      case decodeOrFail $ BL.fromStrict val of
        Left _ -> return Nothing
        Right (record, _ , (index,term)) -> return $ Just $ Entry index term $ LevelDBMessage GetResult tableKey (BL.toStrict record)
    Nothing -> return Nothing

entryToValue :: LevelDBEntry -> ByteString
entryToValue (Entry index term (LevelDBMessage _ _ value)) = BL.toStrict $ runPut action
  where
    action = do
      put index
      put term
      put value

-- instance Binary a => MonadLog LevelDBLog a where
instance MonadResource m => MonadLog (LevelDBLog m) LevelDBMessage where
  logEntry i = do
    let key = encode i
    tlog@(LevelDBLogType _ transactionIndex) <- ask
    mValueKey <- LDB.get transactionIndex LDB.defaultReadOptions $ BL.toStrict key
    case mValueKey of
      Just tableKey -> getEntryFromTable tlog tableKey
      Nothing -> return Nothing

  logLastEntry = do
    tlog@(LevelDBLogType _ transactionIndex) <- ask
    mTableKey <-  LDB.withIterator transactionIndex LDB.defaultReadOptions $ \ iterator -> LDB.iterLast iterator >> LDB.iterValue iterator
    case mTableKey of
      Just tableKey -> getEntryFromTable tlog tableKey
      Nothing -> return Nothing

initializeLog :: MonadResource m => FilePath -> m LevelDBLogType
initializeLog path = do
  table <- LDB.open (path </> "table") LDB.defaultOptions
  transactionIndex <- LDB.open (path </> "index") LDB.defaultOptions
  return $ LevelDBLogType table transactionIndex

writeValue :: MonadResource m => LevelDBLogType -> LevelDBEntry -> m ()
writeValue (LevelDBLogType table index) entry@(Entry _ _ (LevelDBMessage PutRequest key value)) = do
  LDB.put table defaultWriteOptions key $ entryToValue entry
  LDB.put index defaultWriteOptions (BL.toStrict $ encode $ eIndex entry) key

readValue :: MonadResource m => LevelDBLogType -> ByteString -> m (Maybe ByteString)
readValue tlog key = do
  mEntry <- getEntryFromTable tlog key
  return $ fmap (\ (Entry _ _ (LevelDBMessage _ _ value)) -> value) mEntry

truncateLog :: MonadResource m => LevelDBLogType -> Index -> m ()
truncateLog (LevelDBLogType _ index) i = LDB.withIterator index LDB.defaultReadOptions func
  where
    newMinIndex = BL.toStrict $ encode i
    func iterator = do
      LDB.iterNext iterator
      mKey <- LDB.iterKey iterator
      case mKey of
        Just x -> if x <= newMinIndex then LDB.delete index defaultWriteOptions x else func iterator
        Nothing -> return ()

defaultWriteOptions :: LDB.WriteOptions
defaultWriteOptions = LDB.WriteOptions True --All Writes Should be Flushed

runLevelDBLog :: (MonadResource m) => LevelDBLog m r -> LevelDBLogType -> m r
runLevelDBLog = runReaderT . unLevelDBLog

data LevelDBOperationType = PutRequest | GetResult | Delete deriving (Enum,Eq,Show, Generic)

data LevelDBMessage = LevelDBMessage{
  lmOperationType :: LevelDBOperationType,
  lmKey :: ByteString,
  lmValue :: ByteString
} deriving (Eq, Show, Generic)

instance Binary LevelDBOperationType
instance Binary LevelDBMessage
