{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
module Data.Kontiki.LevelDB () where

import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.Reader (MonadReader, Reader, ask, lift, runReader)
import Control.Monad.Trans.Resource
import Data.Binary
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Functor.Identity
import Database.LevelDB (DB)
import qualified Database.LevelDB as LDB
import Network.Kontiki.Raft
import System.FilePath

import Prelude hiding (log)

instance MonadResource Identity where
  liftResourceT = liftResourceT

instance MonadThrow Identity where
  monadThrow = monadThrow

instance MonadUnsafeIO Identity where
  unsafeLiftIO = unsafeLiftIO

instance MonadIO Identity where
  liftIO = liftIO

--LevelDB Layout
--  Your Data Table (your key,your value)
--    Your Value needs to be prefixed with the index and term
--  Transaction Index (index, your key)

data LevelDBLogType = LevelDBLogType DB DB

newtype LevelDBLog r = LevelDBLog {unLevelDBLog :: Reader LevelDBLogType r}
  deriving ( Applicative
           , Functor
           , Monad
           , MonadIO
           , MonadReader LevelDBLogType
           , MonadResource
           , MonadThrow
           , MonadUnsafeIO)

getEntryFromTable :: MonadResource m =>  LevelDBLogType -> ByteString -> m (Maybe (Entry ByteString))
getEntryFromTable (LevelDBLogType table _) tableKey = do
  mVal <- LDB.get table LDB.defaultReadOptions tableKey
  case mVal of
    Just val ->
      case decodeOrFail $ BL.fromStrict val of
        Left _ -> return Nothing
        Right (record, _ , (index,term)) -> return $ Just $ Entry index term $ BL.toStrict record
    Nothing -> return Nothing


instance MonadLog LevelDBLog ByteString where
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
