{-# LANGUAGE FlexibleContexts #-}

module Network.SSH.Client.LibSSH2.Conduit
       ( CommandsHandle
       , execCommand
       , getReturnCode
       , sourceChannel
       , splitLines
       ) where

import Control.Concurrent.STM
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Resource
import Data.Conduit
import Network.SSH.Client.LibSSH2
import Network.SSH.Client.LibSSH2.Foreign

-- | Read all contents of libssh2's Channel.
sourceChannel :: MonadResource m => Channel -> Source m String
sourceChannel ch = src
  where
    src = sourceIO initState defaultClose pull
    pull _state = do
      (sz, res) <- liftIO $ readChannel ch 0x400
      if sz > 0
        then return (IOOpen res)
        else return IOClosed

-- | Similar to Data.Conduit.Binary.lines, but for Strings.
splitLines :: MonadResource m => Conduit String m String
splitLines =
  conduitState id push close
  where
    push front bs' = return $ StateProducing leftover ls
      where
        bs = front bs'
        (leftover, ls) = getLines id bs
    getLines front bs
        | null bs = (id, front [])
        | null y = ((x ++), front [])
        | otherwise = getLines (front . (x:)) (drop 1 y)
      where
        (x, y) = break (== '\n') bs
    close front
        | null bs = return []
        | otherwise = return [bs]
      where
        bs = front ""

-- | Execute one command and read it's output lazily.  If first
-- argument is True, then you *must* get return code using
-- getReturnCode on returned CommandsHandle. Moreover, you *must*
-- guarantee that getReturnCode will be called only when all command
-- output will be read.
execCommand ::
  MonadResource m
  => Bool
  -> Session
  -> String
  -> IO (Maybe CommandsHandle, Source m String)
execCommand returnCodeOnExit sess cmd = do
  (ch, channel) <- initCH returnCodeOnExit sess
  let src = execCommandS ch channel cmd $= splitLines
  return (if returnCodeOnExit then Just ch else Nothing, src)

-- | Handles channel opening and closing.
data CommandsHandle =
  CommandsHandle { chReturnCode    :: Maybe (TMVar Int),
                   chChannel       :: TMVar Channel,
                   chChannelClosed :: TVar Bool }

initCH :: Bool -> Session -> IO (CommandsHandle, Channel)
initCH False s = do
  c <- newTVarIO False
  ch <- newEmptyTMVarIO
  channel <- openCH ch s
  return (CommandsHandle Nothing ch c, channel)
initCH True s = do
  r <- newEmptyTMVarIO
  c <- newTVarIO False
  ch <- newEmptyTMVarIO
  channel <- openCH ch s
  return (CommandsHandle (Just r) ch c, channel)

openCH :: TMVar Channel -> Session -> IO Channel
openCH var s = do
  ch <- openChannelSession s
  atomically $ putTMVar var ch
  return ch

-- | Get return code for previously run command.  It will fail if
-- command was run using execCommand False.  Should be called only
-- when all command output is read.
getReturnCode :: CommandsHandle -> IO Int
getReturnCode ch = do
  c <- atomically $ readTVar (chChannelClosed ch)
  if c
    then do
      case chReturnCode ch of
        Nothing -> fail $ "Channel already closed and no exit"
                   ++ " code return was set up for command."
        Just v -> atomically $ takeTMVar v
    else do
      channel <- atomically $ takeTMVar (chChannel ch)
      cleanupChannel ch channel
      atomically $ writeTVar (chChannelClosed ch) True
      case chReturnCode ch of
        Nothing -> fail "No exit code return was set up for commnand."
        Just v  -> do rc <- atomically $ takeTMVar v
                      return rc

execCommandS ::
  MonadResource m
  => CommandsHandle
  -> Channel
  -> String
  -> Source m String
execCommandS var channel command =
  source (pull channel)
  where
    source = sourceIO initState defaultClose
    next ch = source (pullAnswer ch)
    pullAnswer ch _state = do
      (sz, res) <- liftIO $ readChannel ch 0x400
      if sz > 0
        then return (IOOpen res)
        else do liftIO $ cleanupChannel var ch
                return IOClosed
    pull ch state = do
      liftIO $ channelExecute ch command
      pullAnswer ch state

-- | Close Channel and write return code
cleanupChannel :: CommandsHandle -> Channel -> IO ()
cleanupChannel ch channel = do
  c <- atomically $ readTVar (chChannelClosed ch)
  when (not c) $ do
    closeChannel channel
    case chReturnCode ch of
      Nothing -> return ()
      Just v  -> do
                 exitStatus <- channelExitStatus channel
                 atomically $ putTMVar v exitStatus
    closeChannel channel
    freeChannel channel
    atomically $ writeTVar (chChannelClosed ch) True
    return ()

initState :: IO String
initState  = return ""

defaultClose :: a -> IO ()
defaultClose _ = return ()
