{-# LANGUAGE FlexibleInstances #-}
module Node where

import Control.Concurrent.MVar
import qualified Data.ByteString.Lazy.Char8 as B8
import qualified Data.ByteString.Char8 as SB8
import Network.Socket hiding (send, sendTo, recv, recvFrom)
import Network.Socket.ByteString
import Control.Concurrent.Chan
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Monad

import KRPC


data NodeState = State { stSock :: Socket,
                         stQueryHandler :: QueryHandler,
                         stLastT :: T,
                         stQueries :: Map T (Packet -> IO ())
                       }
type Node = MVar NodeState
type QueryHandler = SockAddr -> Query -> IO (Either Error Reply)

class InState a where
    inState :: a -> Node -> IO ()

instance InState (NodeState -> IO NodeState) where
    inState f node = modifyMVar_ node f

instance InState (NodeState -> IO ()) where
    inState f node = withMVar node f

instance InState (NodeState -> NodeState) where
    inState f node = modifyMVar_ node $ return . f

new :: Int -> IO Node
new port = do sock <- socket AF_INET Datagram defaultProtocol
              bindSocket sock (SockAddrInet (fromIntegral port) 0)
              newMVar $ State { stSock = sock,
                                stQueryHandler = nullQueryHandler,
                                stLastT = T B8.empty,
                                stQueries = Map.empty
                              }

nullQueryHandler _ _ = return $ Left $ Error 201 $ B8.pack "Not implemented"

setQueryHandler :: QueryHandler -> Node -> IO ()
setQueryHandler cb = inState $ \st -> st { stQueryHandler = cb }

run :: Node -> IO ()
run node = runOnce node >>
           run node

runOnce :: Node -> IO ()
runOnce node = do sock <- withMVar node $ return . stSock
                  (buf, addr) <- recvFrom sock 65535
                  let handle st = catch (handlePacket st (B8.fromChunks [buf]) addr) $ \e ->
                                  do putStrLn $ "Error handling packet: " ++ show e
                                     return st
                  inState handle node


handlePacket :: NodeState -> B8.ByteString -> SockAddr -> IO NodeState
handlePacket st buf addr
    = do let pkt = decodePacket buf
             queries = stQueries st
         putStrLn $ "received " ++ show pkt ++ " from " ++ show addr
         let (isReply, isQuery, t) = case pkt of
                                       RPacket t _ -> (True, False, t)
                                       EPacket t _ -> (True, False, t)
                                       QPacket t _ -> (False, True, t)
         case (isReply, isQuery) of
           (True, _) ->
               case Map.lookup t $ queries of
                 Just receiver ->
                     do receiver pkt
                        return st { stQueries = Map.delete t queries }
                 Nothing -> return st
           (False, True) ->
               do let QPacket t qry = pkt
                  qRes <- stQueryHandler st addr qry
                  let pkt = case qRes of
                              Left e -> EPacket t e
                              Right r -> RPacket t r
                      buf = SB8.concat $ B8.toChunks $ encodePacket pkt
                  putStrLn $ "replying " ++ show pkt ++ " to " ++ show addr
                  sendTo (stSock st) buf addr
                  return st

sendQuery :: SockAddr -> Query -> Node -> IO Packet
sendQuery addr qry node
    = do chan <- newChan
         let recvReply = writeChan chan
             send st = do let t = tSucc $ stLastT st
                              pkt = QPacket t qry
                              buf = SB8.concat $ B8.toChunks $ encodePacket $ pkt
                          putStrLn $ "Sending " ++ show pkt ++ " to " ++ show addr
                          sendTo (stSock st) buf addr
                          return st { stLastT = t,
                                      stQueries = Map.insert t recvReply $ stQueries st
                                    }
         inState send node
         readChan chan

getAddrs :: String -> String -> IO [SockAddr]
getAddrs name serv = liftM (map addrAddress .
                            filter ((== AF_INET) . addrFamily)) $
                     getAddrInfo (Just defaultHints { addrFamily = AF_INET })
                     (Just name) (Just serv)
                

