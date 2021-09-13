{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeOperators #-}

module Simplex.Chat.Store
  ( SQLiteStore,
    StoreError (..),
    createStore,
    createUser,
    getUsers,
    setActiveUser,
    createDirectConnection,
    createDirectContact,
    getContactGroupNames,
    deleteContact,
    getContact,
    updateUserProfile,
    updateContactProfile,
    getUserContacts,
    getLiveSndFileTransfers,
    getLiveRcvFileTransfers,
    getPendingSndChunks,
    getPendingConnections,
    getContactConnections,
    getConnectionChatDirection,
    updateConnectionStatus,
    createNewGroup,
    createGroupInvitation,
    getGroup,
    deleteGroup,
    getUserGroups,
    getGroupInvitation,
    createContactGroupMember,
    createMemberConnection,
    updateGroupMemberStatus,
    createNewGroupMember,
    deleteGroupMemberConnection,
    createIntroductions,
    updateIntroStatus,
    saveIntroInvitation,
    createIntroReMember,
    createIntroToMemberContact,
    saveMemberInvitation,
    getViaGroupMember,
    getViaGroupContact,
    getMatchingContacts,
    randomBytes,
    createSentProbe,
    createSentProbeHash,
    matchReceivedProbe,
    matchReceivedProbeHash,
    matchSentProbe,
    mergeContactRecords,
    createSndFileTransfer,
    createSndGroupFileTransfer,
    updateSndFileStatus,
    createSndFileChunk,
    updateSndFileChunkMsg,
    updateSndFileChunkSent,
    deleteSndFileChunks,
    createRcvFileTransfer,
    createRcvGroupFileTransfer,
    getRcvFileTransfer,
    acceptRcvFileTransfer,
    updateRcvFileStatus,
    createRcvFileChunk,
    updatedRcvFileChunkStored,
    deleteRcvFileChunks,
    getFileTransfer,
    getFileTransferProgress,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent.STM (stateTVar)
import Control.Exception (Exception)
import qualified Control.Exception as E
import Control.Monad.Except
import Control.Monad.IO.Unlift
import Crypto.Random (ChaChaDRG, randomBytesGenerate)
import qualified Data.ByteString.Base64 as B64
import Data.ByteString.Char8 (ByteString)
import Data.Either (rights)
import Data.FileEmbed (embedDir, makeRelativeToProject)
import Data.Function (on)
import Data.Functor (($>))
import Data.Int (Int64)
import Data.List (find, sortBy)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Database.SQLite.Simple (NamedParam (..), Only (..), SQLError, (:.) (..))
import qualified Database.SQLite.Simple as DB
import Database.SQLite.Simple.QQ (sql)
import Simplex.Chat.Protocol
import Simplex.Chat.Types
import Simplex.Messaging.Agent.Protocol (AParty (..), AgentMsgId, ConnId, SMPQueueInfo)
import Simplex.Messaging.Agent.Store.SQLite (SQLiteStore (..), createSQLiteStore, withTransaction)
import Simplex.Messaging.Agent.Store.SQLite.Migrations (Migration (..))
import qualified Simplex.Messaging.Crypto as C
import Simplex.Messaging.Util (bshow, liftIOEither, (<$$>))
import System.FilePath (takeBaseName, takeExtension, takeFileName)
import UnliftIO.STM

-- | The list of migrations in ascending order by date
migrations :: [Migration]
migrations =
  sortBy (compare `on` name) . map migration . filter sqlFile $
    $(makeRelativeToProject "migrations" >>= embedDir)
  where
    sqlFile (file, _) = takeExtension file == ".sql"
    migration (file, qStr) = Migration {name = takeBaseName file, up = decodeUtf8 qStr}

createStore :: FilePath -> Int -> IO SQLiteStore
createStore dbFilePath poolSize = createSQLiteStore dbFilePath poolSize migrations

checkConstraint :: StoreError -> IO (Either StoreError a) -> IO (Either StoreError a)
checkConstraint err action = action `E.catch` (pure . Left . handleSQLError err)

handleSQLError :: StoreError -> SQLError -> StoreError
handleSQLError err e
  | DB.sqlError e == DB.ErrorConstraint = err
  | otherwise = SEInternal $ bshow e

insertedRowId :: DB.Connection -> IO Int64
insertedRowId db = fromOnly . head <$> DB.query_ db "SELECT last_insert_rowid()"

type StoreMonad m = (MonadUnliftIO m, MonadError StoreError m)

createUser :: StoreMonad m => SQLiteStore -> Profile -> Bool -> m User
createUser st Profile {displayName, fullName} activeUser =
  liftIOEither . checkConstraint SEDuplicateName . withTransaction st $ \db -> do
    DB.execute db "INSERT INTO users (local_display_name, active_user, contact_id) VALUES (?, ?, 0)" (displayName, activeUser)
    userId <- insertedRowId db
    DB.execute db "INSERT INTO display_names (local_display_name, ldn_base, user_id) VALUES (?, ?, ?)" (displayName, displayName, userId)
    DB.execute db "INSERT INTO contact_profiles (display_name, full_name) VALUES (?, ?)" (displayName, fullName)
    profileId <- insertedRowId db
    DB.execute db "INSERT INTO contacts (contact_profile_id, local_display_name, user_id, is_user) VALUES (?, ?, ?, ?)" (profileId, displayName, userId, True)
    contactId <- insertedRowId db
    DB.execute db "UPDATE users SET contact_id = ? WHERE user_id = ?" (contactId, userId)
    pure . Right $ toUser (userId, contactId, activeUser, displayName, fullName)

getUsers :: SQLiteStore -> IO [User]
getUsers st =
  withTransaction st $ \db ->
    map toUser
      <$> DB.query_
        db
        [sql|
          SELECT u.user_id, u.contact_id, u.active_user, u.local_display_name, p.full_name
          FROM users u
          JOIN contacts c ON u.contact_id = c.contact_id
          JOIN contact_profiles p ON c.contact_profile_id = p.contact_profile_id
        |]

toUser :: (UserId, Int64, Bool, ContactName, Text) -> User
toUser (userId, userContactId, activeUser, displayName, fullName) =
  let profile = Profile {displayName, fullName}
   in User {userId, userContactId, localDisplayName = displayName, profile, activeUser}

setActiveUser :: MonadUnliftIO m => SQLiteStore -> UserId -> m ()
setActiveUser st userId = do
  liftIO . withTransaction st $ \db -> do
    DB.execute_ db "UPDATE users SET active_user = 0"
    DB.execute db "UPDATE users SET active_user = 1 WHERE user_id = ?" (Only userId)

createDirectConnection :: MonadUnliftIO m => SQLiteStore -> UserId -> ConnId -> m ()
createDirectConnection st userId agentConnId =
  liftIO . withTransaction st $ \db ->
    void $ createConnection_ db userId agentConnId Nothing 0

createConnection_ :: DB.Connection -> UserId -> ConnId -> Maybe Int64 -> Int -> IO Connection
createConnection_ db userId agentConnId viaContact connLevel = do
  createdAt <- getCurrentTime
  DB.execute
    db
    [sql|
      INSERT INTO connections
        (user_id, agent_conn_id, conn_status, conn_type, via_contact, conn_level, created_at) VALUES (?,?,?,?,?,?,?);
    |]
    (userId, agentConnId, ConnNew, ConnContact, viaContact, connLevel, createdAt)
  connId <- insertedRowId db
  pure Connection {connId, agentConnId, connType = ConnContact, entityId = Nothing, viaContact, connLevel, connStatus = ConnNew, createdAt}

createDirectContact :: StoreMonad m => SQLiteStore -> UserId -> Connection -> Profile -> m ()
createDirectContact st userId Connection {connId} profile =
  void $
    liftIOEither . withTransaction st $ \db ->
      createContact_ db userId connId profile Nothing

createContact_ :: DB.Connection -> UserId -> Int64 -> Profile -> Maybe Int64 -> IO (Either StoreError (Text, Int64, Int64))
createContact_ db userId connId Profile {displayName, fullName} viaGroup =
  withLocalDisplayName db userId displayName $ \ldn -> do
    DB.execute db "INSERT INTO contact_profiles (display_name, full_name) VALUES (?, ?)" (displayName, fullName)
    profileId <- insertedRowId db
    DB.execute db "INSERT INTO contacts (contact_profile_id, local_display_name, user_id, via_group) VALUES (?,?,?,?)" (profileId, ldn, userId, viaGroup)
    contactId <- insertedRowId db
    DB.execute db "UPDATE connections SET contact_id = ? WHERE connection_id = ?" (contactId, connId)
    pure (ldn, contactId, profileId)

getContactGroupNames :: MonadUnliftIO m => SQLiteStore -> UserId -> ContactName -> m [GroupName]
getContactGroupNames st userId displayName =
  liftIO . withTransaction st $ \db -> do
    map fromOnly
      <$> DB.query
        db
        [sql|
          SELECT DISTINCT g.local_display_name
          FROM groups g
          JOIN group_members m ON m.group_id = g.group_id
          WHERE g.user_id = ? AND m.local_display_name = ?
        |]
        (userId, displayName)

deleteContact :: MonadUnliftIO m => SQLiteStore -> UserId -> ContactName -> m ()
deleteContact st userId displayName =
  liftIO . withTransaction st $ \db -> do
    DB.executeNamed
      db
      [sql|
        DELETE FROM connections WHERE connection_id IN (
          SELECT connection_id
          FROM connections c
          JOIN contacts cs ON c.contact_id = cs.contact_id
          WHERE cs.user_id = :user_id AND cs.local_display_name = :display_name
        )
      |]
      [":user_id" := userId, ":display_name" := displayName]
    DB.executeNamed
      db
      [sql|
        DELETE FROM contacts
        WHERE user_id = :user_id AND local_display_name = :display_name
      |]
      [":user_id" := userId, ":display_name" := displayName]
    DB.executeNamed
      db
      [sql|
        DELETE FROM display_names
        WHERE user_id = :user_id AND local_display_name = :display_name
      |]
      [":user_id" := userId, ":display_name" := displayName]

getContact :: StoreMonad m => SQLiteStore -> UserId -> ContactName -> m Contact
getContact st userId localDisplayName =
  liftIOEither . withTransaction st $ \db -> runExceptT $ getContact_ db userId localDisplayName

updateUserProfile :: StoreMonad m => SQLiteStore -> User -> Profile -> m User
updateUserProfile st u@User {userId, userContactId, localDisplayName, profile = Profile {displayName}} p'@Profile {displayName = newName}
  | displayName == newName =
    liftIO . withTransaction st $ \db ->
      updateContactProfile_ db userId userContactId p' $> (u :: User) {profile = p'}
  | otherwise =
    liftIOEither . checkConstraint SEDuplicateName . withTransaction st $ \db -> do
      DB.execute db "UPDATE users SET local_display_name = ? WHERE user_id = ?" (newName, userId)
      DB.execute db "INSERT INTO display_names (local_display_name, ldn_base, user_id) VALUES (?, ?, ?)" (newName, newName, userId)
      updateContactProfile_ db userId userContactId p'
      updateContact_ db userId userContactId localDisplayName newName
      pure . Right $ (u :: User) {localDisplayName = newName, profile = p'}

updateContactProfile :: StoreMonad m => SQLiteStore -> UserId -> Contact -> Profile -> m Contact
updateContactProfile st userId c@Contact {contactId, localDisplayName, profile = Profile {displayName}} p'@Profile {displayName = newName}
  | displayName == newName =
    liftIO . withTransaction st $ \db ->
      updateContactProfile_ db userId contactId p' $> (c :: Contact) {profile = p'}
  | otherwise =
    liftIOEither . withTransaction st $ \db ->
      withLocalDisplayName db userId newName $ \ldn -> do
        updateContactProfile_ db userId contactId p'
        updateContact_ db userId contactId localDisplayName ldn
        pure $ (c :: Contact) {localDisplayName = ldn, profile = p'}

updateContactProfile_ :: DB.Connection -> UserId -> Int64 -> Profile -> IO ()
updateContactProfile_ db userId contactId Profile {displayName, fullName} =
  DB.executeNamed
    db
    [sql|
      UPDATE contact_profiles
      SET display_name = :display_name,
          full_name = :full_name
      WHERE contact_profile_id IN (
        SELECT contact_profile_id
        FROM contacts
        WHERE user_id = :user_id
          AND contact_id = :contact_id
      )
    |]
    [ ":display_name" := displayName,
      ":full_name" := fullName,
      ":user_id" := userId,
      ":contact_id" := contactId
    ]

updateContact_ :: DB.Connection -> UserId -> Int64 -> ContactName -> ContactName -> IO ()
updateContact_ db userId contactId displayName newName = do
  DB.execute db "UPDATE contacts SET local_display_name = ? WHERE user_id = ? AND contact_id = ?" (newName, userId, contactId)
  DB.execute db "UPDATE group_members SET local_display_name = ? WHERE user_id = ? AND contact_id = ?" (newName, userId, contactId)
  DB.execute db "DELETE FROM display_names WHERE local_display_name = ? AND user_id = ?" (displayName, userId)

-- TODO return the last connection that is ready, not any last connection
-- requires updating connection status
getContact_ :: DB.Connection -> UserId -> ContactName -> ExceptT StoreError IO Contact
getContact_ db userId localDisplayName = do
  c@Contact {contactId} <- getContactRec_
  activeConn <- getConnection_ contactId
  pure $ (c :: Contact) {activeConn}
  where
    getContactRec_ :: ExceptT StoreError IO Contact
    getContactRec_ = ExceptT $ do
      toContact
        <$> DB.queryNamed
          db
          [sql|
            SELECT c.contact_id, p.display_name, p.full_name, c.via_group
            FROM contacts c
            JOIN contact_profiles p ON c.contact_profile_id = p.contact_profile_id
            WHERE c.user_id = :user_id AND c.local_display_name = :local_display_name AND c.is_user = :is_user
          |]
          [":user_id" := userId, ":local_display_name" := localDisplayName, ":is_user" := False]
    getConnection_ :: Int64 -> ExceptT StoreError IO Connection
    getConnection_ contactId = ExceptT $ do
      connection
        <$> DB.queryNamed
          db
          [sql|
            SELECT c.connection_id, c.agent_conn_id, c.conn_level, c.via_contact,
              c.conn_status, c.conn_type, c.contact_id, c.group_member_id, c.snd_file_id, c.rcv_file_id, c.created_at
            FROM connections c
            WHERE c.user_id = :user_id AND c.contact_id == :contact_id
            ORDER BY c.connection_id DESC
            LIMIT 1
          |]
          [":user_id" := userId, ":contact_id" := contactId]
    toContact :: [(Int64, Text, Text, Maybe Int64)] -> Either StoreError Contact
    toContact [(contactId, displayName, fullName, viaGroup)] =
      let profile = Profile {displayName, fullName}
       in Right Contact {contactId, localDisplayName, profile, activeConn = undefined, viaGroup}
    toContact _ = Left $ SEContactNotFound localDisplayName
    connection :: [ConnectionRow] -> Either StoreError Connection
    connection (connRow : _) = Right $ toConnection connRow
    connection _ = Left $ SEContactNotReady localDisplayName

getUserContacts :: MonadUnliftIO m => SQLiteStore -> User -> m [Contact]
getUserContacts st User {userId} =
  liftIO . withTransaction st $ \db -> do
    contactNames <- map fromOnly <$> DB.query db "SELECT local_display_name FROM contacts WHERE user_id = ?" (Only userId)
    rights <$> mapM (runExceptT . getContact_ db userId) contactNames

getLiveSndFileTransfers :: MonadUnliftIO m => SQLiteStore -> User -> m [SndFileTransfer]
getLiveSndFileTransfers st User {userId} =
  liftIO . withTransaction st $ \db -> do
    fileIds :: [Int64] <-
      map fromOnly
        <$> DB.query
          db
          [sql|
            SELECT DISTINCT f.file_id
            FROM files f
            JOIN snd_files s
            WHERE f.user_id = ? AND s.file_status IN (?, ?, ?)
          |]
          (userId, FSNew, FSAccepted, FSConnected)
    concatMap (filter liveTransfer) . rights <$> mapM (getSndFileTransfers_ db userId) fileIds
  where
    liveTransfer :: SndFileTransfer -> Bool
    liveTransfer SndFileTransfer {fileStatus} = fileStatus `elem` [FSNew, FSAccepted, FSConnected]

getLiveRcvFileTransfers :: MonadUnliftIO m => SQLiteStore -> User -> m [RcvFileTransfer]
getLiveRcvFileTransfers st User {userId} =
  liftIO . withTransaction st $ \db -> do
    fileIds :: [Int64] <-
      map fromOnly
        <$> DB.query
          db
          [sql|
            SELECT f.file_id
            FROM files f
            JOIN rcv_files r
            WHERE f.user_id = ? AND r.file_status IN (?, ?)
          |]
          (userId, FSAccepted, FSConnected)
    rights <$> mapM (getRcvFileTransfer_ db userId) fileIds

getPendingSndChunks :: MonadUnliftIO m => SQLiteStore -> Int64 -> Int64 -> m [Integer]
getPendingSndChunks st fileId connId =
  liftIO . withTransaction st $ \db ->
    map fromOnly
      <$> DB.query
        db
        [sql|
          SELECT chunk_number
          FROM snd_file_chunks
          WHERE file_id = ? AND connection_id = ? AND chunk_agent_msg_id IS NULL
          ORDER BY chunk_number
        |]
        (fileId, connId)

getPendingConnections :: MonadUnliftIO m => SQLiteStore -> User -> m [Connection]
getPendingConnections st User {userId} =
  liftIO . withTransaction st $ \db ->
    map toConnection
      <$> DB.queryNamed
        db
        [sql|
          SELECT connection_id, agent_conn_id, conn_level, via_contact,
            conn_status, conn_type, contact_id, group_member_id, snd_file_id, rcv_file_id, created_at
          FROM connections
          WHERE user_id = :user_id
            AND conn_type = :conn_type
            AND contact_id IS NULL
        |]
        [":user_id" := userId, ":conn_type" := ConnContact]

getContactConnections :: StoreMonad m => SQLiteStore -> UserId -> ContactName -> m [Connection]
getContactConnections st userId displayName =
  liftIOEither . withTransaction st $ \db ->
    connections
      <$> DB.queryNamed
        db
        [sql|
          SELECT c.connection_id, c.agent_conn_id, c.conn_level, c.via_contact,
            c.conn_status, c.conn_type, c.contact_id, c.group_member_id, c.snd_file_id, c.rcv_file_id, c.created_at
          FROM connections c
          JOIN contacts cs ON c.contact_id == cs.contact_id
          WHERE c.user_id = :user_id
            AND cs.user_id = :user_id
            AND cs.local_display_name == :display_name
        |]
        [":user_id" := userId, ":display_name" := displayName]
  where
    connections [] = Left $ SEContactNotFound displayName
    connections rows = Right $ map toConnection rows

type ConnectionRow = (Int64, ConnId, Int, Maybe Int64, ConnStatus, ConnType, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64, UTCTime)

type MaybeConnectionRow = (Maybe Int64, Maybe ConnId, Maybe Int, Maybe Int64, Maybe ConnStatus, Maybe ConnType, Maybe Int64, Maybe Int64, Maybe Int64, Maybe Int64, Maybe UTCTime)

toConnection :: ConnectionRow -> Connection
toConnection (connId, agentConnId, connLevel, viaContact, connStatus, connType, contactId, groupMemberId, sndFileId, rcvFileId, createdAt) =
  let entityId = entityId_ connType
   in Connection {connId, agentConnId, connLevel, viaContact, connStatus, connType, entityId, createdAt}
  where
    entityId_ :: ConnType -> Maybe Int64
    entityId_ ConnContact = contactId
    entityId_ ConnMember = groupMemberId
    entityId_ ConnRcvFile = rcvFileId
    entityId_ ConnSndFile = sndFileId

toMaybeConnection :: MaybeConnectionRow -> Maybe Connection
toMaybeConnection (Just connId, Just agentConnId, Just connLevel, viaContact, Just connStatus, Just connType, contactId, groupMemberId, sndFileId, rcvFileId, Just createdAt) =
  Just $ toConnection (connId, agentConnId, connLevel, viaContact, connStatus, connType, contactId, groupMemberId, sndFileId, rcvFileId, createdAt)
toMaybeConnection _ = Nothing

getMatchingContacts :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> m [Contact]
getMatchingContacts st userId Contact {contactId, profile = Profile {displayName, fullName}} =
  liftIO . withTransaction st $ \db -> do
    contactNames <-
      map fromOnly
        <$> DB.queryNamed
          db
          [sql|
            SELECT ct.local_display_name
            FROM contacts ct
            JOIN contact_profiles p ON ct.contact_profile_id = p.contact_profile_id
            WHERE ct.user_id = :user_id AND ct.contact_id != :contact_id
              AND p.display_name = :display_name AND p.full_name = :full_name
          |]
          [ ":user_id" := userId,
            ":contact_id" := contactId,
            ":display_name" := displayName,
            ":full_name" := fullName
          ]
    rights <$> mapM (runExceptT . getContact_ db userId) contactNames

createSentProbe :: StoreMonad m => SQLiteStore -> TVar ChaChaDRG -> UserId -> Contact -> m (ByteString, Int64)
createSentProbe st gVar userId _to@Contact {contactId} =
  liftIOEither . withTransaction st $ \db ->
    createWithRandomBytes 32 gVar $ \probe -> do
      DB.execute db "INSERT INTO sent_probes (contact_id, probe, user_id) VALUES (?,?,?)" (contactId, probe, userId)
      (probe,) <$> insertedRowId db

createSentProbeHash :: MonadUnliftIO m => SQLiteStore -> UserId -> Int64 -> Contact -> m ()
createSentProbeHash st userId probeId _to@Contact {contactId} =
  liftIO . withTransaction st $ \db ->
    DB.execute db "INSERT INTO sent_probe_hashes (sent_probe_id, contact_id, user_id) VALUES (?,?,?)" (probeId, contactId, userId)

matchReceivedProbe :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> ByteString -> m (Maybe Contact)
matchReceivedProbe st userId _from@Contact {contactId} probe =
  liftIO . withTransaction st $ \db -> do
    let probeHash = C.sha256Hash probe
    contactNames <-
      map fromOnly
        <$> DB.query
          db
          [sql|
            SELECT c.local_display_name
            FROM contacts c
            JOIN received_probes r ON r.contact_id = c.contact_id
            WHERE c.user_id = ? AND r.probe_hash = ? AND r.probe IS NULL
          |]
          (userId, probeHash)
    DB.execute db "INSERT INTO received_probes (contact_id, probe, probe_hash, user_id) VALUES (?,?,?,?)" (contactId, probe, probeHash, userId)
    case contactNames of
      [] -> pure Nothing
      cName : _ ->
        either (const Nothing) Just
          <$> runExceptT (getContact_ db userId cName)

matchReceivedProbeHash :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> ByteString -> m (Maybe (Contact, ByteString))
matchReceivedProbeHash st userId _from@Contact {contactId} probeHash =
  liftIO . withTransaction st $ \db -> do
    namesAndProbes <-
      DB.query
        db
        [sql|
          SELECT c.local_display_name, r.probe
          FROM contacts c
          JOIN received_probes r ON r.contact_id = c.contact_id
          WHERE c.user_id = ? AND r.probe_hash = ? AND r.probe IS NOT NULL
        |]
        (userId, probeHash)
    DB.execute db "INSERT INTO received_probes (contact_id, probe_hash, user_id) VALUES (?,?,?)" (contactId, probeHash, userId)
    case namesAndProbes of
      [] -> pure Nothing
      (cName, probe) : _ ->
        either (const Nothing) (Just . (,probe))
          <$> runExceptT (getContact_ db userId cName)

matchSentProbe :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> ByteString -> m (Maybe Contact)
matchSentProbe st userId _from@Contact {contactId} probe =
  liftIO . withTransaction st $ \db -> do
    contactNames <-
      map fromOnly
        <$> DB.query
          db
          [sql|
            SELECT c.local_display_name
            FROM contacts c
            JOIN sent_probes s ON s.contact_id = c.contact_id
            JOIN sent_probe_hashes h ON h.sent_probe_id = s.sent_probe_id
            WHERE c.user_id = ? AND s.probe = ? AND h.contact_id = ?
          |]
          (userId, probe, contactId)
    case contactNames of
      [] -> pure Nothing
      cName : _ ->
        either (const Nothing) Just
          <$> runExceptT (getContact_ db userId cName)

mergeContactRecords :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> Contact -> m ()
mergeContactRecords st userId Contact {contactId = toContactId} Contact {contactId = fromContactId, localDisplayName} =
  liftIO . withTransaction st $ \db -> do
    DB.execute db "UPDATE connections SET contact_id = ? WHERE contact_id = ? AND user_id = ?" (toContactId, fromContactId, userId)
    DB.execute db "UPDATE connections SET via_contact = ? WHERE via_contact = ? AND user_id = ?" (toContactId, fromContactId, userId)
    DB.execute db "UPDATE group_members SET invited_by = ? WHERE invited_by = ? AND user_id = ?" (toContactId, fromContactId, userId)
    DB.execute db "UPDATE direct_chat_items SET contact_id = ? WHERE contact_id = ?" (toContactId, fromContactId)
    DB.executeNamed
      db
      [sql|
        UPDATE group_members
        SET contact_id = :to_contact_id,
            local_display_name = (SELECT local_display_name FROM contacts WHERE contact_id = :to_contact_id),
            contact_profile_id = (SELECT contact_profile_id FROM contacts WHERE contact_id = :to_contact_id)
        WHERE contact_id = :from_contact_id
          AND user_id = :user_id
      |]
      [ ":to_contact_id" := toContactId,
        ":from_contact_id" := fromContactId,
        ":user_id" := userId
      ]
    DB.execute db "DELETE FROM contacts WHERE contact_id = ? AND user_id = ?" (fromContactId, userId)
    DB.execute db "DELETE FROM display_names WHERE local_display_name = ? AND user_id = ?" (localDisplayName, userId)

getConnectionChatDirection :: StoreMonad m => SQLiteStore -> User -> ConnId -> m (ChatDirection 'Agent)
getConnectionChatDirection st User {userId, userContactId} agentConnId =
  liftIOEither . withTransaction st $ \db -> runExceptT $ do
    c@Connection {connType, entityId} <- getConnection_ db
    case entityId of
      Nothing ->
        if connType == ConnContact
          then pure $ ReceivedDirectMessage c Nothing
          else throwError $ SEInternal $ "connection " <> bshow connType <> " without entity"
      Just entId ->
        case connType of
          ConnMember -> uncurry (ReceivedGroupMessage c) <$> getGroupAndMember_ db entId c
          ConnContact -> ReceivedDirectMessage c . Just <$> getContactRec_ db entId c
          ConnSndFile -> SndFileConnection c <$> getConnSndFileTransfer_ db entId c
          ConnRcvFile -> RcvFileConnection c <$> ExceptT (getRcvFileTransfer_ db userId entId)
  where
    getConnection_ :: DB.Connection -> ExceptT StoreError IO Connection
    getConnection_ db = ExceptT $ do
      connection
        <$> DB.query
          db
          [sql|
            SELECT connection_id, agent_conn_id, conn_level, via_contact,
              conn_status, conn_type, contact_id, group_member_id, snd_file_id, rcv_file_id, created_at
            FROM connections
            WHERE user_id = ? AND agent_conn_id = ?
          |]
          (userId, agentConnId)
    connection :: [ConnectionRow] -> Either StoreError Connection
    connection (connRow : _) = Right $ toConnection connRow
    connection _ = Left $ SEConnectionNotFound agentConnId
    getContactRec_ :: DB.Connection -> Int64 -> Connection -> ExceptT StoreError IO Contact
    getContactRec_ db contactId c = ExceptT $ do
      toContact contactId c
        <$> DB.query
          db
          [sql|
            SELECT c.local_display_name, p.display_name, p.full_name, c.via_group
            FROM contacts c
            JOIN contact_profiles p ON c.contact_profile_id = p.contact_profile_id
            WHERE c.user_id = ? AND c.contact_id = ?
          |]
          (userId, contactId)
    toContact :: Int64 -> Connection -> [(ContactName, Text, Text, Maybe Int64)] -> Either StoreError Contact
    toContact contactId activeConn [(localDisplayName, displayName, fullName, viaGroup)] =
      let profile = Profile {displayName, fullName}
       in Right $ Contact {contactId, localDisplayName, profile, activeConn, viaGroup}
    toContact _ _ _ = Left $ SEInternal "referenced contact not found"
    getGroupAndMember_ :: DB.Connection -> Int64 -> Connection -> ExceptT StoreError IO (GroupName, GroupMember)
    getGroupAndMember_ db groupMemberId c = ExceptT $ do
      toGroupAndMember c
        <$> DB.query
          db
          [sql|
            SELECT
              g.local_display_name,
              m.group_member_id, m.group_id, m.member_id, m.member_role, m.member_category, m.member_status,
              m.invited_by, m.local_display_name, m.contact_id, p.display_name, p.full_name
            FROM group_members m
            JOIN contact_profiles p ON p.contact_profile_id = m.contact_profile_id
            JOIN groups g ON g.group_id = m.group_id
            WHERE m.group_member_id = ?
          |]
          (Only groupMemberId)
    toGroupAndMember :: Connection -> [Only GroupName :. GroupMemberRow] -> Either StoreError (GroupName, GroupMember)
    toGroupAndMember c [Only groupName :. memberRow] =
      let member = toGroupMember userContactId memberRow
       in Right (groupName, (member :: GroupMember) {activeConn = Just c})
    toGroupAndMember _ _ = Left $ SEInternal "referenced group member not found"
    getConnSndFileTransfer_ :: DB.Connection -> Int64 -> Connection -> ExceptT StoreError IO SndFileTransfer
    getConnSndFileTransfer_ db fileId Connection {connId} =
      ExceptT $
        sndFileTransfer_ fileId connId
          <$> DB.query
            db
            [sql|
              SELECT s.file_status, f.file_name, f.file_size, f.chunk_size, f.file_path, cs.local_display_name, m.local_display_name
              FROM snd_files s
              JOIN files f USING (file_id)
              LEFT JOIN contacts cs USING (contact_id)
              LEFT JOIN group_members m USING (group_member_id)    
              WHERE f.user_id = ? AND f.file_id = ? AND s.connection_id = ?
            |]
            (userId, fileId, connId)
    sndFileTransfer_ :: Int64 -> Int64 -> [(FileStatus, String, Integer, Integer, FilePath, Maybe ContactName, Maybe ContactName)] -> Either StoreError SndFileTransfer
    sndFileTransfer_ fileId connId [(fileStatus, fileName, fileSize, chunkSize, filePath, contactName_, memberName_)] =
      case contactName_ <|> memberName_ of
        Just recipientDisplayName -> Right SndFileTransfer {..}
        Nothing -> Left $ SESndFileInvalid fileId
    sndFileTransfer_ fileId _ _ = Left $ SESndFileNotFound fileId

updateConnectionStatus :: MonadUnliftIO m => SQLiteStore -> Connection -> ConnStatus -> m ()
updateConnectionStatus st Connection {connId} connStatus =
  liftIO . withTransaction st $ \db ->
    DB.execute db "UPDATE connections SET conn_status = ? WHERE connection_id = ?" (connStatus, connId)

-- | creates completely new group with a single member - the current user
createNewGroup :: StoreMonad m => SQLiteStore -> TVar ChaChaDRG -> User -> GroupProfile -> m Group
createNewGroup st gVar user groupProfile =
  liftIOEither . checkConstraint SEDuplicateName . withTransaction st $ \db -> do
    let GroupProfile {displayName, fullName} = groupProfile
        uId = userId user
    DB.execute db "INSERT INTO display_names (local_display_name, ldn_base, user_id) VALUES (?, ?, ?)" (displayName, displayName, uId)
    DB.execute db "INSERT INTO group_profiles (display_name, full_name) VALUES (?, ?)" (displayName, fullName)
    profileId <- insertedRowId db
    DB.execute db "INSERT INTO groups (local_display_name, user_id, group_profile_id) VALUES (?, ?, ?)" (displayName, uId, profileId)
    groupId <- insertedRowId db
    memberId <- randomBytes gVar 12
    membership <- createContactMember_ db user groupId user (memberId, GROwner) GCUserMember GSMemCreator IBUser
    pure $ Right Group {groupId, localDisplayName = displayName, groupProfile, members = [], membership}

-- | creates a new group record for the group the current user was invited to
createGroupInvitation ::
  StoreMonad m => SQLiteStore -> User -> Contact -> GroupInvitation -> m Group
createGroupInvitation st user contact GroupInvitation {fromMember, invitedMember, queueInfo, groupProfile} =
  liftIOEither . withTransaction st $ \db -> do
    let GroupProfile {displayName, fullName} = groupProfile
        uId = userId user
    withLocalDisplayName db uId displayName $ \localDisplayName -> do
      DB.execute db "INSERT INTO group_profiles (display_name, full_name) VALUES (?, ?)" (displayName, fullName)
      profileId <- insertedRowId db
      DB.execute db "INSERT INTO groups (group_profile_id, local_display_name, inv_queue_info, user_id) VALUES (?, ?, ?, ?)" (profileId, localDisplayName, queueInfo, uId)
      groupId <- insertedRowId db
      member <- createContactMember_ db user groupId contact fromMember GCHostMember GSMemInvited IBUnknown
      membership <- createContactMember_ db user groupId user invitedMember GCUserMember GSMemInvited (IBContact $ contactId contact)
      pure Group {groupId, localDisplayName, groupProfile, members = [member], membership}

-- TODO return the last connection that is ready, not any last connection
-- requires updating connection status
getGroup :: StoreMonad m => SQLiteStore -> User -> GroupName -> m Group
getGroup st user localDisplayName =
  liftIOEither . withTransaction st $ \db -> runExceptT $ fst <$> getGroup_ db user localDisplayName

getGroup_ :: DB.Connection -> User -> GroupName -> ExceptT StoreError IO (Group, Maybe SMPQueueInfo)
getGroup_ db User {userId, userContactId} localDisplayName = do
  (g@Group {groupId}, qInfo) <- getGroupRec_
  allMembers <- getMembers_ groupId
  (members, membership) <- liftEither $ splitUserMember_ allMembers
  pure (g {members, membership}, qInfo)
  where
    getGroupRec_ :: ExceptT StoreError IO (Group, Maybe SMPQueueInfo)
    getGroupRec_ = ExceptT $ do
      toGroup
        <$> DB.query
          db
          [sql|
            SELECT g.group_id, p.display_name, p.full_name, g.inv_queue_info
            FROM groups g
            JOIN group_profiles p ON p.group_profile_id = g.group_profile_id
            WHERE g.local_display_name = ? AND g.user_id = ?
          |]
          (localDisplayName, userId)
    toGroup :: [(Int64, GroupName, Text, Maybe SMPQueueInfo)] -> Either StoreError (Group, Maybe SMPQueueInfo)
    toGroup [(groupId, displayName, fullName, qInfo)] =
      let groupProfile = GroupProfile {displayName, fullName}
       in Right (Group {groupId, localDisplayName, groupProfile, members = undefined, membership = undefined}, qInfo)
    toGroup _ = Left $ SEGroupNotFound localDisplayName
    getMembers_ :: Int64 -> ExceptT StoreError IO [GroupMember]
    getMembers_ groupId = ExceptT $ do
      Right . map toContactMember
        <$> DB.query
          db
          [sql|
            SELECT
              m.group_member_id, m.group_id, m.member_id, m.member_role, m.member_category, m.member_status,
              m.invited_by, m.local_display_name, m.contact_id, p.display_name, p.full_name,
              c.connection_id, c.agent_conn_id, c.conn_level, c.via_contact,
              c.conn_status, c.conn_type, c.contact_id, c.group_member_id, c.snd_file_id, c.rcv_file_id, c.created_at
            FROM group_members m
            JOIN contact_profiles p ON p.contact_profile_id = m.contact_profile_id
            LEFT JOIN connections c ON c.connection_id = (
              SELECT max(cc.connection_id)
              FROM connections cc
              where cc.group_member_id = m.group_member_id
            )
            WHERE m.group_id = ? AND m.user_id = ?
          |]
          (groupId, userId)
    toContactMember :: (GroupMemberRow :. MaybeConnectionRow) -> GroupMember
    toContactMember (memberRow :. connRow) =
      (toGroupMember userContactId memberRow) {activeConn = toMaybeConnection connRow}
    splitUserMember_ :: [GroupMember] -> Either StoreError ([GroupMember], GroupMember)
    splitUserMember_ allMembers =
      let (b, a) = break ((== Just userContactId) . memberContactId) allMembers
       in case a of
            [] -> Left SEGroupWithoutUser
            u : ms -> Right (b <> ms, u)

deleteGroup :: MonadUnliftIO m => SQLiteStore -> User -> Group -> m ()
deleteGroup st User {userId} Group {groupId, members, localDisplayName} =
  liftIO . withTransaction st $ \db -> do
    forM_ members $ \m -> DB.execute db "DELETE FROM connections WHERE user_id = ? AND group_member_id = ?" (userId, groupMemberId m)
    DB.execute db "DELETE FROM group_members WHERE user_id = ? AND group_id = ?" (userId, groupId)
    DB.execute db "DELETE FROM groups WHERE user_id = ? AND group_id = ?" (userId, groupId)
    DB.execute db "DELETE FROM display_names WHERE user_id = ? AND local_display_name = ?" (userId, localDisplayName)

getUserGroups :: MonadUnliftIO m => SQLiteStore -> User -> m [Group]
getUserGroups st user =
  liftIO . withTransaction st $ \db -> do
    groupNames <- liftIO $ map fromOnly <$> DB.query db "SELECT local_display_name FROM groups WHERE user_id = ?" (Only $ userId user)
    map fst . rights <$> mapM (runExceptT . getGroup_ db user) groupNames

getGroupInvitation :: StoreMonad m => SQLiteStore -> User -> GroupName -> m ReceivedGroupInvitation
getGroupInvitation st user localDisplayName =
  liftIOEither . withTransaction st $ \db -> runExceptT $ do
    (Group {membership, members, groupProfile}, qInfo) <- getGroup_ db user localDisplayName
    when (memberStatus membership /= GSMemInvited) $ throwError SEGroupAlreadyJoined
    case (qInfo, findFromContact (invitedBy membership) members) of
      (Just queueInfo, Just fromMember) ->
        pure ReceivedGroupInvitation {fromMember, userMember = membership, queueInfo, groupProfile}
      _ -> throwError SEGroupInvitationNotFound
  where
    findFromContact :: InvitedBy -> [GroupMember] -> Maybe GroupMember
    findFromContact (IBContact contactId) = find ((== Just contactId) . memberContactId)
    findFromContact _ = const Nothing

type GroupMemberRow = (Int64, Int64, ByteString, GroupMemberRole, GroupMemberCategory, GroupMemberStatus, Maybe Int64, ContactName, Maybe Int64, ContactName, Text)

toGroupMember :: Int64 -> GroupMemberRow -> GroupMember
toGroupMember userContactId (groupMemberId, groupId, memberId, memberRole, memberCategory, memberStatus, invitedById, localDisplayName, memberContactId, displayName, fullName) =
  let memberProfile = Profile {displayName, fullName}
      invitedBy = toInvitedBy userContactId invitedById
      activeConn = Nothing
   in GroupMember {..}

createContactGroupMember :: StoreMonad m => SQLiteStore -> TVar ChaChaDRG -> User -> Int64 -> Contact -> GroupMemberRole -> ConnId -> m GroupMember
createContactGroupMember st gVar user groupId contact memberRole agentConnId =
  liftIOEither . withTransaction st $ \db ->
    createWithRandomId gVar $ \memId -> do
      member <- createContactMember_ db user groupId contact (memId, memberRole) GCInviteeMember GSMemInvited IBUser
      groupMemberId <- insertedRowId db
      void $ createMemberConnection_ db (userId user) groupMemberId agentConnId Nothing 0
      pure member

createMemberConnection :: MonadUnliftIO m => SQLiteStore -> UserId -> GroupMember -> ConnId -> m ()
createMemberConnection st userId GroupMember {groupMemberId} agentConnId =
  liftIO . withTransaction st $ \db ->
    void $ createMemberConnection_ db userId groupMemberId agentConnId Nothing 0

updateGroupMemberStatus :: MonadUnliftIO m => SQLiteStore -> UserId -> GroupMember -> GroupMemberStatus -> m ()
updateGroupMemberStatus st userId GroupMember {groupMemberId} memStatus =
  liftIO . withTransaction st $ \db ->
    DB.executeNamed
      db
      [sql|
        UPDATE group_members
        SET member_status = :member_status
        WHERE user_id = :user_id AND group_member_id = :group_member_id
      |]
      [ ":user_id" := userId,
        ":group_member_id" := groupMemberId,
        ":member_status" := memStatus
      ]

-- | add new member with profile
createNewGroupMember :: StoreMonad m => SQLiteStore -> User -> Group -> MemberInfo -> GroupMemberCategory -> GroupMemberStatus -> m GroupMember
createNewGroupMember st user@User {userId} group memInfo@(MemberInfo _ _ Profile {displayName, fullName}) memCategory memStatus =
  liftIOEither . withTransaction st $ \db ->
    withLocalDisplayName db userId displayName $ \localDisplayName -> do
      DB.execute db "INSERT INTO contact_profiles (display_name, full_name) VALUES (?, ?)" (displayName, fullName)
      memProfileId <- insertedRowId db
      let newMember =
            NewGroupMember
              { memInfo,
                memCategory,
                memStatus,
                memInvitedBy = IBUnknown,
                localDisplayName,
                memContactId = Nothing,
                memProfileId
              }
      createNewMember_ db user group newMember

createNewMember_ :: DB.Connection -> User -> Group -> NewGroupMember -> IO GroupMember
createNewMember_
  db
  User {userId, userContactId}
  Group {groupId}
  NewGroupMember
    { memInfo = MemberInfo memberId memberRole memberProfile,
      memCategory = memberCategory,
      memStatus = memberStatus,
      memInvitedBy = invitedBy,
      localDisplayName,
      memContactId = memberContactId,
      memProfileId
    } = do
    let invitedById = fromInvitedBy userContactId invitedBy
        activeConn = Nothing
    DB.execute
      db
      [sql|
        INSERT INTO group_members
          (group_id, member_id, member_role, member_category, member_status,
           invited_by, user_id, local_display_name, contact_profile_id, contact_id) VALUES (?,?,?,?,?,?,?,?,?,?)
      |]
      (groupId, memberId, memberRole, memberCategory, memberStatus, invitedById, userId, localDisplayName, memProfileId, memberContactId)
    groupMemberId <- insertedRowId db
    pure GroupMember {..}

deleteGroupMemberConnection :: MonadUnliftIO m => SQLiteStore -> UserId -> GroupMember -> m ()
deleteGroupMemberConnection st userId m =
  liftIO . withTransaction st $ \db -> deleteGroupMemberConnection_ db userId m

deleteGroupMemberConnection_ :: DB.Connection -> UserId -> GroupMember -> IO ()
deleteGroupMemberConnection_ db userId GroupMember {groupMemberId} =
  DB.execute db "DELETE FROM connections WHERE user_id = ? AND group_member_id = ?" (userId, groupMemberId)

createIntroductions :: MonadUnliftIO m => SQLiteStore -> Group -> GroupMember -> m [GroupMemberIntro]
createIntroductions st Group {members} toMember = do
  let reMembers = filter (\m -> memberCurrent m && groupMemberId m /= groupMemberId toMember) members
  if null reMembers
    then pure []
    else liftIO . withTransaction st $ \db ->
      mapM (insertIntro_ db) reMembers
  where
    insertIntro_ :: DB.Connection -> GroupMember -> IO GroupMemberIntro
    insertIntro_ db reMember = do
      DB.execute
        db
        [sql|
          INSERT INTO group_member_intros
            (re_group_member_id, to_group_member_id, intro_status) VALUES (?,?,?)
        |]
        (groupMemberId reMember, groupMemberId toMember, GMIntroPending)
      introId <- insertedRowId db
      pure GroupMemberIntro {introId, reMember, toMember, introStatus = GMIntroPending, introInvitation = Nothing}

updateIntroStatus :: MonadUnliftIO m => SQLiteStore -> GroupMemberIntro -> GroupMemberIntroStatus -> m ()
updateIntroStatus st GroupMemberIntro {introId} introStatus' =
  liftIO . withTransaction st $ \db ->
    DB.executeNamed
      db
      [sql|
        UPDATE group_member_intros
        SET intro_status = :intro_status
        WHERE group_member_intro_id = :intro_id
      |]
      [":intro_status" := introStatus', ":intro_id" := introId]

saveIntroInvitation :: StoreMonad m => SQLiteStore -> GroupMember -> GroupMember -> IntroInvitation -> m GroupMemberIntro
saveIntroInvitation st reMember toMember introInv = do
  liftIOEither . withTransaction st $ \db -> runExceptT $ do
    intro <- getIntroduction_ db reMember toMember
    liftIO $
      DB.executeNamed
        db
        [sql|
          UPDATE group_member_intros
          SET intro_status = :intro_status,
              group_queue_info = :group_queue_info,
              direct_queue_info = :direct_queue_info
          WHERE group_member_intro_id = :intro_id
        |]
        [ ":intro_status" := GMIntroInvReceived,
          ":group_queue_info" := groupQInfo introInv,
          ":direct_queue_info" := directQInfo introInv,
          ":intro_id" := introId intro
        ]
    pure intro {introInvitation = Just introInv, introStatus = GMIntroInvReceived}

saveMemberInvitation :: StoreMonad m => SQLiteStore -> GroupMember -> IntroInvitation -> m ()
saveMemberInvitation st GroupMember {groupMemberId} IntroInvitation {groupQInfo, directQInfo} =
  liftIO . withTransaction st $ \db ->
    DB.executeNamed
      db
      [sql|
        UPDATE group_members
        SET member_status = :member_status,
            group_queue_info = :group_queue_info,
            direct_queue_info = :direct_queue_info
        WHERE group_member_id = :group_member_id
      |]
      [ ":member_status" := GSMemIntroInvited,
        ":group_queue_info" := groupQInfo,
        ":direct_queue_info" := directQInfo,
        ":group_member_id" := groupMemberId
      ]

getIntroduction_ :: DB.Connection -> GroupMember -> GroupMember -> ExceptT StoreError IO GroupMemberIntro
getIntroduction_ db reMember toMember = ExceptT $ do
  toIntro
    <$> DB.query
      db
      [sql|
        SELECT group_member_intro_id, group_queue_info, direct_queue_info, intro_status
        FROM group_member_intros
        WHERE re_group_member_id = ? AND to_group_member_id = ?
      |]
      (groupMemberId reMember, groupMemberId toMember)
  where
    toIntro :: [(Int64, Maybe SMPQueueInfo, Maybe SMPQueueInfo, GroupMemberIntroStatus)] -> Either StoreError GroupMemberIntro
    toIntro [(introId, groupQInfo, directQInfo, introStatus)] =
      let introInvitation = IntroInvitation <$> groupQInfo <*> directQInfo
       in Right GroupMemberIntro {introId, reMember, toMember, introStatus, introInvitation}
    toIntro _ = Left SEIntroNotFound

createIntroReMember :: StoreMonad m => SQLiteStore -> User -> Group -> GroupMember -> MemberInfo -> ConnId -> ConnId -> m GroupMember
createIntroReMember st user@User {userId} group@Group {groupId} _host@GroupMember {memberContactId, activeConn} memInfo@(MemberInfo _ _ memberProfile) groupAgentConnId directAgentConnId =
  liftIOEither . withTransaction st $ \db -> runExceptT $ do
    let cLevel = 1 + maybe 0 (connLevel :: Connection -> Int) activeConn
    Connection {connId = directConnId} <- liftIO $ createConnection_ db userId directAgentConnId memberContactId cLevel
    (localDisplayName, contactId, memProfileId) <- ExceptT $ createContact_ db userId directConnId memberProfile (Just groupId)
    liftIO $ do
      let newMember =
            NewGroupMember
              { memInfo,
                memCategory = GCPreMember,
                memStatus = GSMemIntroduced,
                memInvitedBy = IBUnknown,
                localDisplayName,
                memContactId = Just contactId,
                memProfileId
              }
      member <- createNewMember_ db user group newMember
      conn <- createMemberConnection_ db userId (groupMemberId member) groupAgentConnId memberContactId cLevel
      pure (member :: GroupMember) {activeConn = Just conn}

createIntroToMemberContact :: StoreMonad m => SQLiteStore -> UserId -> GroupMember -> GroupMember -> ConnId -> ConnId -> m ()
createIntroToMemberContact st userId GroupMember {memberContactId = viaContactId, activeConn} _to@GroupMember {groupMemberId, localDisplayName} groupAgentConnId directAgentConnId =
  liftIO . withTransaction st $ \db -> do
    let cLevel = 1 + maybe 0 (connLevel :: Connection -> Int) activeConn
    void $ createMemberConnection_ db userId groupMemberId groupAgentConnId viaContactId cLevel
    Connection {connId = directConnId} <- createConnection_ db userId directAgentConnId viaContactId cLevel
    contactId <- createMemberContact_ db directConnId
    updateMember_ db contactId
  where
    createMemberContact_ :: DB.Connection -> Int64 -> IO Int64
    createMemberContact_ db connId = do
      DB.executeNamed
        db
        [sql|
          INSERT INTO contacts (contact_profile_id, via_group, local_display_name, user_id)
          SELECT contact_profile_id, group_id, :local_display_name, :user_id
          FROM group_members
          WHERE group_member_id = :group_member_id
        |]
        [ ":group_member_id" := groupMemberId,
          ":local_display_name" := localDisplayName,
          ":user_id" := userId
        ]
      contactId <- insertedRowId db
      DB.execute db "UPDATE connections SET contact_id = ? WHERE connection_id = ?" (contactId, connId)
      pure contactId
    updateMember_ :: DB.Connection -> Int64 -> IO ()
    updateMember_ db contactId =
      DB.executeNamed
        db
        [sql|
          UPDATE group_members
          SET contact_id = :contact_id
          WHERE group_member_id = :group_member_id
        |]
        [":contact_id" := contactId, ":group_member_id" := groupMemberId]

createMemberConnection_ :: DB.Connection -> UserId -> Int64 -> ConnId -> Maybe Int64 -> Int -> IO Connection
createMemberConnection_ db userId groupMemberId agentConnId viaContact connLevel = do
  createdAt <- getCurrentTime
  DB.execute
    db
    [sql|
      INSERT INTO connections
        (user_id, agent_conn_id, conn_status, conn_type, group_member_id, via_contact, conn_level, created_at) VALUES (?,?,?,?,?,?,?,?);
    |]
    (userId, agentConnId, ConnNew, ConnMember, groupMemberId, viaContact, connLevel, createdAt)
  connId <- insertedRowId db
  pure Connection {connId, agentConnId, connType = ConnMember, entityId = Just groupMemberId, viaContact, connLevel, connStatus = ConnNew, createdAt}

createContactMember_ :: IsContact a => DB.Connection -> User -> Int64 -> a -> (MemberId, GroupMemberRole) -> GroupMemberCategory -> GroupMemberStatus -> InvitedBy -> IO GroupMember
createContactMember_ db User {userId, userContactId} groupId userOrContact (memberId, memberRole) memberCategory memberStatus invitedBy = do
  insertMember_
  groupMemberId <- insertedRowId db
  let memberProfile = profile' userOrContact
      memberContactId = Just $ contactId' userOrContact
      localDisplayName = localDisplayName' userOrContact
      activeConn = Nothing
  pure GroupMember {..}
  where
    insertMember_ =
      DB.executeNamed
        db
        [sql|
          INSERT INTO group_members
            ( group_id, member_id, member_role, member_category, member_status, invited_by,
              user_id, local_display_name, contact_profile_id, contact_id)
          VALUES
            (:group_id,:member_id,:member_role,:member_category,:member_status,:invited_by,
             :user_id,:local_display_name,
              (SELECT contact_profile_id FROM contacts WHERE contact_id = :contact_id),
              :contact_id)
        |]
        [ ":group_id" := groupId,
          ":member_id" := memberId,
          ":member_role" := memberRole,
          ":member_category" := memberCategory,
          ":member_status" := memberStatus,
          ":invited_by" := fromInvitedBy userContactId invitedBy,
          ":user_id" := userId,
          ":local_display_name" := localDisplayName' userOrContact,
          ":contact_id" := contactId' userOrContact
        ]

getViaGroupMember :: MonadUnliftIO m => SQLiteStore -> User -> Contact -> m (Maybe (GroupName, GroupMember))
getViaGroupMember st User {userId, userContactId} Contact {contactId} =
  liftIO . withTransaction st $ \db ->
    toGroupAndMember
      <$> DB.query
        db
        [sql|
          SELECT
            g.local_display_name,
            m.group_member_id, m.group_id, m.member_id, m.member_role, m.member_category, m.member_status,
            m.invited_by, m.local_display_name, m.contact_id, p.display_name, p.full_name,
            c.connection_id, c.agent_conn_id, c.conn_level, c.via_contact,
            c.conn_status, c.conn_type, c.contact_id, c.group_member_id, c.snd_file_id, c.rcv_file_id, c.created_at
          FROM group_members m
          JOIN contacts ct ON ct.contact_id = m.contact_id
          JOIN contact_profiles p ON p.contact_profile_id = m.contact_profile_id
          JOIN groups g ON g.group_id = m.group_id AND g.group_id = ct.via_group
          LEFT JOIN connections c ON c.connection_id = (
            SELECT max(cc.connection_id)
            FROM connections cc
            where cc.group_member_id = m.group_member_id
          )
          WHERE ct.user_id = ? AND ct.contact_id = ?
        |]
        (userId, contactId)
  where
    toGroupAndMember :: [Only GroupName :. GroupMemberRow :. MaybeConnectionRow] -> Maybe (GroupName, GroupMember)
    toGroupAndMember [Only groupName :. memberRow :. connRow] =
      let member = toGroupMember userContactId memberRow
       in Just (groupName, (member :: GroupMember) {activeConn = toMaybeConnection connRow})
    toGroupAndMember _ = Nothing

getViaGroupContact :: MonadUnliftIO m => SQLiteStore -> User -> GroupMember -> m (Maybe Contact)
getViaGroupContact st User {userId} GroupMember {groupMemberId} =
  liftIO . withTransaction st $ \db ->
    toContact
      <$> DB.query
        db
        [sql|
          SELECT
            ct.contact_id, ct.local_display_name, p.display_name, p.full_name, ct.via_group,
            c.connection_id, c.agent_conn_id, c.conn_level, c.via_contact,
            c.conn_status, c.conn_type, c.contact_id, c.group_member_id, c.snd_file_id, c.rcv_file_id, c.created_at
          FROM contacts ct
          JOIN contact_profiles p ON ct.contact_profile_id = p.contact_profile_id
          JOIN connections c ON c.connection_id = (
            SELECT max(cc.connection_id)
            FROM connections cc
            where cc.contact_id = ct.contact_id
          )
          JOIN groups g ON g.group_id = ct.via_group
          JOIN group_members m ON m.group_id = g.group_id AND m.contact_id = ct.contact_id
          WHERE ct.user_id = ? AND m.group_member_id = ?
        |]
        (userId, groupMemberId)
  where
    toContact :: [(Int64, ContactName, Text, Text, Maybe Int64) :. ConnectionRow] -> Maybe Contact
    toContact [(contactId, localDisplayName, displayName, fullName, viaGroup) :. connRow] =
      let profile = Profile {displayName, fullName}
          activeConn = toConnection connRow
       in Just Contact {contactId, localDisplayName, profile, activeConn, viaGroup}
    toContact _ = Nothing

createSndFileTransfer :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> FilePath -> FileInvitation -> ConnId -> Integer -> m SndFileTransfer
createSndFileTransfer st userId Contact {contactId, localDisplayName = recipientDisplayName} filePath FileInvitation {fileName, fileSize} agentConnId chunkSize =
  liftIO . withTransaction st $ \db -> do
    DB.execute db "INSERT INTO files (user_id, contact_id, file_name, file_path, file_size, chunk_size) VALUES (?, ?, ?, ?, ?, ?)" (userId, contactId, fileName, filePath, fileSize, chunkSize)
    fileId <- insertedRowId db
    Connection {connId} <- createSndFileConnection_ db userId fileId agentConnId
    let fileStatus = FSNew
    DB.execute db "INSERT INTO snd_files (file_id, file_status, connection_id) VALUES (?, ?, ?)" (fileId, fileStatus, connId)
    pure SndFileTransfer {..}

createSndGroupFileTransfer :: MonadUnliftIO m => SQLiteStore -> UserId -> Group -> [(GroupMember, ConnId, FileInvitation)] -> FilePath -> Integer -> Integer -> m Int64
createSndGroupFileTransfer st userId Group {groupId} ms filePath fileSize chunkSize =
  liftIO . withTransaction st $ \db -> do
    let fileName = takeFileName filePath
    DB.execute db "INSERT INTO files (user_id, group_id, file_name, file_path, file_size, chunk_size) VALUES (?, ?, ?, ?, ?, ?)" (userId, groupId, fileName, filePath, fileSize, chunkSize)
    fileId <- insertedRowId db
    forM_ ms $ \(GroupMember {groupMemberId}, agentConnId, _) -> do
      Connection {connId} <- createSndFileConnection_ db userId fileId agentConnId
      DB.execute db "INSERT INTO snd_files (file_id, file_status, connection_id, group_member_id) VALUES (?, ?, ?, ?)" (fileId, FSNew, connId, groupMemberId)
    pure fileId

createSndFileConnection_ :: DB.Connection -> UserId -> Int64 -> ConnId -> IO Connection
createSndFileConnection_ db userId fileId agentConnId = do
  createdAt <- getCurrentTime
  let connType = ConnSndFile
      connStatus = ConnNew
  DB.execute
    db
    [sql|
      INSERT INTO connections
        (user_id, snd_file_id, agent_conn_id, conn_status, conn_type, created_at) VALUES (?,?,?,?,?,?)
    |]
    (userId, fileId, agentConnId, connStatus, connType, createdAt)
  connId <- insertedRowId db
  pure Connection {connId, agentConnId, connType, entityId = Just fileId, viaContact = Nothing, connLevel = 0, connStatus, createdAt}

updateSndFileStatus :: MonadUnliftIO m => SQLiteStore -> SndFileTransfer -> FileStatus -> m ()
updateSndFileStatus st SndFileTransfer {fileId, connId} status =
  liftIO . withTransaction st $ \db ->
    DB.execute db "UPDATE snd_files SET file_status = ? WHERE file_id = ? AND connection_id = ?" (status, fileId, connId)

createSndFileChunk :: MonadUnliftIO m => SQLiteStore -> SndFileTransfer -> m (Maybe Integer)
createSndFileChunk st SndFileTransfer {fileId, connId, fileSize, chunkSize} =
  liftIO . withTransaction st $ \db -> do
    chunkNo <- getLastChunkNo db
    insertChunk db chunkNo
    pure chunkNo
  where
    getLastChunkNo db = do
      ns <- DB.query db "SELECT chunk_number FROM snd_file_chunks WHERE file_id = ? AND connection_id = ? AND chunk_sent = 1 ORDER BY chunk_number DESC LIMIT 1" (fileId, connId)
      pure $ case map fromOnly ns of
        [] -> Just 1
        n : _ -> if n * chunkSize >= fileSize then Nothing else Just (n + 1)
    insertChunk db = \case
      Just chunkNo -> DB.execute db "INSERT OR REPLACE INTO snd_file_chunks (file_id, connection_id, chunk_number) VALUES (?, ?, ?)" (fileId, connId, chunkNo)
      Nothing -> pure ()

updateSndFileChunkMsg :: MonadUnliftIO m => SQLiteStore -> SndFileTransfer -> Integer -> AgentMsgId -> m ()
updateSndFileChunkMsg st SndFileTransfer {fileId, connId} chunkNo msgId =
  liftIO . withTransaction st $ \db ->
    DB.execute
      db
      [sql|
        UPDATE snd_file_chunks
        SET chunk_agent_msg_id = ?
        WHERE file_id = ? AND connection_id = ? AND chunk_number = ?
      |]
      (msgId, fileId, connId, chunkNo)

updateSndFileChunkSent :: MonadUnliftIO m => SQLiteStore -> SndFileTransfer -> AgentMsgId -> m ()
updateSndFileChunkSent st SndFileTransfer {fileId, connId} msgId =
  liftIO . withTransaction st $ \db ->
    DB.execute
      db
      [sql|
        UPDATE snd_file_chunks
        SET chunk_sent = 1
        WHERE file_id = ? AND connection_id = ? AND chunk_agent_msg_id = ?
      |]
      (fileId, connId, msgId)

deleteSndFileChunks :: MonadUnliftIO m => SQLiteStore -> SndFileTransfer -> m ()
deleteSndFileChunks st SndFileTransfer {fileId, connId} =
  liftIO . withTransaction st $ \db ->
    DB.execute db "DELETE FROM snd_file_chunks WHERE file_id = ? AND connection_id = ?" (fileId, connId)

createRcvFileTransfer :: MonadUnliftIO m => SQLiteStore -> UserId -> Contact -> FileInvitation -> Integer -> m RcvFileTransfer
createRcvFileTransfer st userId Contact {contactId, localDisplayName = c} f@FileInvitation {fileName, fileSize, fileQInfo} chunkSize =
  liftIO . withTransaction st $ \db -> do
    DB.execute db "INSERT INTO files (user_id, contact_id, file_name, file_size, chunk_size) VALUES (?, ?, ?, ?, ?)" (userId, contactId, fileName, fileSize, chunkSize)
    fileId <- insertedRowId db
    DB.execute db "INSERT INTO rcv_files (file_id, file_status, file_queue_info) VALUES (?, ?, ?)" (fileId, FSNew, fileQInfo)
    pure RcvFileTransfer {fileId, fileInvitation = f, fileStatus = RFSNew, senderDisplayName = c, chunkSize}

createRcvGroupFileTransfer :: MonadUnliftIO m => SQLiteStore -> UserId -> GroupMember -> FileInvitation -> Integer -> m RcvFileTransfer
createRcvGroupFileTransfer st userId GroupMember {groupId, groupMemberId, localDisplayName = c} f@FileInvitation {fileName, fileSize, fileQInfo} chunkSize =
  liftIO . withTransaction st $ \db -> do
    DB.execute db "INSERT INTO files (user_id, group_id, file_name, file_size, chunk_size) VALUES (?, ?, ?, ?, ?)" (userId, groupId, fileName, fileSize, chunkSize)
    fileId <- insertedRowId db
    DB.execute db "INSERT INTO rcv_files (file_id, file_status, file_queue_info, group_member_id) VALUES (?, ?, ?, ?)" (fileId, FSNew, fileQInfo, groupMemberId)
    pure RcvFileTransfer {fileId, fileInvitation = f, fileStatus = RFSNew, senderDisplayName = c, chunkSize}

getRcvFileTransfer :: StoreMonad m => SQLiteStore -> UserId -> Int64 -> m RcvFileTransfer
getRcvFileTransfer st userId fileId =
  liftIOEither . withTransaction st $ \db ->
    getRcvFileTransfer_ db userId fileId

getRcvFileTransfer_ :: DB.Connection -> UserId -> Int64 -> IO (Either StoreError RcvFileTransfer)
getRcvFileTransfer_ db userId fileId =
  rcvFileTransfer
    <$> DB.query
      db
      [sql|
          SELECT r.file_status, r.file_queue_info, f.file_name,
            f.file_size, f.chunk_size, cs.local_display_name, m.local_display_name,
            f.file_path, c.connection_id, c.agent_conn_id
          FROM rcv_files r
          JOIN files f USING (file_id)
          LEFT JOIN connections c ON r.file_id = c.rcv_file_id
          LEFT JOIN contacts cs USING (contact_id)
          LEFT JOIN group_members m USING (group_member_id)
          WHERE f.user_id = ? AND f.file_id = ?
        |]
      (userId, fileId)
  where
    rcvFileTransfer ::
      [(FileStatus, SMPQueueInfo, String, Integer, Integer, Maybe ContactName, Maybe ContactName, Maybe FilePath, Maybe Int64, Maybe ConnId)] ->
      Either StoreError RcvFileTransfer
    rcvFileTransfer [(fileStatus', fileQInfo, fileName, fileSize, chunkSize, contactName_, memberName_, filePath_, connId_, agentConnId_)] =
      let fileInv = FileInvitation {fileName, fileSize, fileQInfo}
          fileInfo = (filePath_, connId_, agentConnId_)
       in case contactName_ <|> memberName_ of
            Nothing -> Left $ SERcvFileInvalid fileId
            Just name ->
              case fileStatus' of
                FSNew -> Right RcvFileTransfer {fileId, fileInvitation = fileInv, fileStatus = RFSNew, senderDisplayName = name, chunkSize}
                FSAccepted -> ft name fileInv RFSAccepted fileInfo
                FSConnected -> ft name fileInv RFSConnected fileInfo
                FSComplete -> ft name fileInv RFSComplete fileInfo
                FSCancelled -> ft name fileInv RFSCancelled fileInfo
      where
        ft senderDisplayName fileInvitation rfs = \case
          (Just filePath, Just connId, Just agentConnId) ->
            let fileStatus = rfs RcvFileInfo {filePath, connId, agentConnId}
             in Right RcvFileTransfer {..}
          _ -> Left $ SERcvFileInvalid fileId
    rcvFileTransfer _ = Left $ SERcvFileNotFound fileId

acceptRcvFileTransfer :: StoreMonad m => SQLiteStore -> UserId -> Int64 -> ConnId -> FilePath -> m ()
acceptRcvFileTransfer st userId fileId agentConnId filePath =
  liftIO . withTransaction st $ \db -> do
    DB.execute db "UPDATE files SET file_path = ? WHERE user_id = ? AND file_id = ?" (filePath, userId, fileId)
    DB.execute db "UPDATE rcv_files SET file_status = ? WHERE file_id = ?" (FSAccepted, fileId)

    DB.execute db "INSERT INTO connections (agent_conn_id, conn_status, conn_type, rcv_file_id, user_id) VALUES (?, ?, ?, ?, ?)" (agentConnId, ConnJoined, ConnRcvFile, fileId, userId)

updateRcvFileStatus :: MonadUnliftIO m => SQLiteStore -> RcvFileTransfer -> FileStatus -> m ()
updateRcvFileStatus st RcvFileTransfer {fileId} status =
  liftIO . withTransaction st $ \db ->
    DB.execute db "UPDATE rcv_files SET file_status = ? WHERE file_id = ?" (status, fileId)

createRcvFileChunk :: MonadUnliftIO m => SQLiteStore -> RcvFileTransfer -> Integer -> AgentMsgId -> m RcvChunkStatus
createRcvFileChunk st RcvFileTransfer {fileId, fileInvitation = FileInvitation {fileSize}, chunkSize} chunkNo msgId =
  liftIO . withTransaction st $ \db -> do
    status <- getLastChunkNo db
    unless (status == RcvChunkError) $
      DB.execute db "INSERT OR REPLACE INTO rcv_file_chunks (file_id, chunk_number, chunk_agent_msg_id) VALUES (?, ?, ?)" (fileId, chunkNo, msgId)
    pure status
  where
    getLastChunkNo db = do
      ns <- DB.query db "SELECT chunk_number FROM rcv_file_chunks WHERE file_id = ? ORDER BY chunk_number DESC LIMIT 1" (Only fileId)
      pure $ case map fromOnly ns of
        [] -> if chunkNo == 1 then RcvChunkOk else RcvChunkError
        n : _
          | chunkNo == n -> RcvChunkDuplicate
          | chunkNo == n + 1 ->
            let prevSize = n * chunkSize
             in if prevSize >= fileSize
                  then RcvChunkError
                  else
                    if prevSize + chunkSize >= fileSize
                      then RcvChunkFinal
                      else RcvChunkOk
          | otherwise -> RcvChunkError

updatedRcvFileChunkStored :: MonadUnliftIO m => SQLiteStore -> RcvFileTransfer -> Integer -> m ()
updatedRcvFileChunkStored st RcvFileTransfer {fileId} chunkNo =
  liftIO . withTransaction st $ \db ->
    DB.execute
      db
      [sql|
        UPDATE rcv_file_chunks
        SET chunk_stored = 1
        WHERE file_id = ? AND chunk_number = ?
      |]
      (fileId, chunkNo)

deleteRcvFileChunks :: MonadUnliftIO m => SQLiteStore -> RcvFileTransfer -> m ()
deleteRcvFileChunks st RcvFileTransfer {fileId} =
  liftIO . withTransaction st $ \db ->
    DB.execute db "DELETE FROM rcv_file_chunks WHERE file_id = ?" (Only fileId)

getFileTransfer :: StoreMonad m => SQLiteStore -> UserId -> Int64 -> m FileTransfer
getFileTransfer st userId fileId =
  liftIOEither . withTransaction st $ \db ->
    getFileTransfer_ db userId fileId

getFileTransferProgress :: StoreMonad m => SQLiteStore -> UserId -> Int64 -> m (FileTransfer, [Integer])
getFileTransferProgress st userId fileId =
  liftIOEither . withTransaction st $ \db -> runExceptT $ do
    ft <- ExceptT $ getFileTransfer_ db userId fileId
    liftIO $
      (ft,) . map fromOnly <$> case ft of
        FTSnd _ -> DB.query db "SELECT COUNT(*) FROM snd_file_chunks WHERE file_id = ? and chunk_sent = 1 GROUP BY connection_id" (Only fileId)
        FTRcv _ -> DB.query db "SELECT COUNT(*) FROM rcv_file_chunks WHERE file_id = ? AND chunk_stored = 1" (Only fileId)

getFileTransfer_ :: DB.Connection -> UserId -> Int64 -> IO (Either StoreError FileTransfer)
getFileTransfer_ db userId fileId =
  fileTransfer
    =<< DB.query
      db
      [sql|
        SELECT s.file_id, r.file_id
        FROM files f
        LEFT JOIN snd_files s ON s.file_id = f.file_id
        LEFT JOIN rcv_files r ON r.file_id = f.file_id
        WHERE user_id = ? AND f.file_id = ?
      |]
      (userId, fileId)
  where
    fileTransfer :: [(Maybe Int64, Maybe Int64)] -> IO (Either StoreError FileTransfer)
    fileTransfer ((Just _, Nothing) : _) = FTSnd <$$> getSndFileTransfers_ db userId fileId
    fileTransfer [(Nothing, Just _)] = FTRcv <$$> getRcvFileTransfer_ db userId fileId
    fileTransfer _ = pure . Left $ SEFileNotFound fileId

getSndFileTransfers_ :: DB.Connection -> UserId -> Int64 -> IO (Either StoreError [SndFileTransfer])
getSndFileTransfers_ db userId fileId =
  sndFileTransfers
    <$> DB.query
      db
      [sql|
        SELECT s.file_status, f.file_name, f.file_size, f.chunk_size, f.file_path, s.connection_id, c.agent_conn_id,
          cs.local_display_name, m.local_display_name
        FROM snd_files s
        JOIN files f USING (file_id)
        JOIN connections c USING (connection_id)
        LEFT JOIN contacts cs USING (contact_id)
        LEFT JOIN group_members m USING (group_member_id)
        WHERE f.user_id = ? AND f.file_id = ?
      |]
      (userId, fileId)
  where
    sndFileTransfers :: [(FileStatus, String, Integer, Integer, FilePath, Int64, ConnId, Maybe ContactName, Maybe ContactName)] -> Either StoreError [SndFileTransfer]
    sndFileTransfers [] = Left $ SESndFileNotFound fileId
    sndFileTransfers fts = mapM sndFileTransfer fts
    sndFileTransfer (fileStatus, fileName, fileSize, chunkSize, filePath, connId, agentConnId, contactName_, memberName_) =
      case contactName_ <|> memberName_ of
        Just recipientDisplayName -> Right SndFileTransfer {..}
        Nothing -> Left $ SESndFileInvalid fileId

-- | Saves unique local display name based on passed displayName, suffixed with _N if required.
-- This function should be called inside transaction.
withLocalDisplayName :: forall a. DB.Connection -> UserId -> Text -> (Text -> IO a) -> IO (Either StoreError a)
withLocalDisplayName db userId displayName action = getLdnSuffix >>= (`tryCreateName` 20)
  where
    getLdnSuffix :: IO Int
    getLdnSuffix =
      maybe 0 ((+ 1) . fromOnly) . listToMaybe
        <$> DB.queryNamed
          db
          [sql|
            SELECT ldn_suffix FROM display_names
            WHERE user_id = :user_id AND ldn_base = :display_name
            ORDER BY ldn_suffix DESC
            LIMIT 1
          |]
          [":user_id" := userId, ":display_name" := displayName]
    tryCreateName :: Int -> Int -> IO (Either StoreError a)
    tryCreateName _ 0 = pure $ Left SEDuplicateName
    tryCreateName ldnSuffix attempts = do
      let ldn = displayName <> (if ldnSuffix == 0 then "" else T.pack $ '_' : show ldnSuffix)
      E.try (insertName ldn) >>= \case
        Right () -> Right <$> action ldn
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreateName (ldnSuffix + 1) (attempts - 1)
          | otherwise -> E.throwIO e
      where
        insertName ldn =
          DB.execute
            db
            [sql|
              INSERT INTO display_names
                (local_display_name, ldn_base, ldn_suffix, user_id) VALUES (?, ?, ?, ?)
            |]
            (ldn, displayName, ldnSuffix, userId)

createWithRandomId :: forall a. TVar ChaChaDRG -> (ByteString -> IO a) -> IO (Either StoreError a)
createWithRandomId = createWithRandomBytes 12

createWithRandomBytes :: forall a. Int -> TVar ChaChaDRG -> (ByteString -> IO a) -> IO (Either StoreError a)
createWithRandomBytes size gVar create = tryCreate 3
  where
    tryCreate :: Int -> IO (Either StoreError a)
    tryCreate 0 = pure $ Left SEUniqueID
    tryCreate n = do
      id' <- randomBytes gVar size
      E.try (create id') >>= \case
        Right x -> pure $ Right x
        Left e
          | DB.sqlError e == DB.ErrorConstraint -> tryCreate (n - 1)
          | otherwise -> pure . Left . SEInternal $ bshow e

randomBytes :: TVar ChaChaDRG -> Int -> IO ByteString
randomBytes gVar n = B64.encode <$> (atomically . stateTVar gVar $ randomBytesGenerate n)

data StoreError
  = SEDuplicateName
  | SEContactNotFound ContactName
  | SEContactNotReady ContactName
  | SEGroupNotFound GroupName
  | SEGroupWithoutUser
  | SEDuplicateGroupMember
  | SEGroupAlreadyJoined
  | SEGroupInvitationNotFound
  | SESndFileNotFound Int64
  | SESndFileInvalid Int64
  | SERcvFileNotFound Int64
  | SEFileNotFound Int64
  | SERcvFileInvalid Int64
  | SEConnectionNotFound ConnId
  | SEIntroNotFound
  | SEUniqueID
  | SEInternal ByteString
  deriving (Show, Exception)
