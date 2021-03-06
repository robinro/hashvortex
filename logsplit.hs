module Main where

import System.IO
import Data.Map (Map)
import qualified Data.Map as Map
import Control.Monad
import Data.Char (isDigit, isAlpha, isSpace)
import Control.Monad.State.Lazy


type Time = Double

data EventStats = EventStats { esFile :: Handle,
                               esTimes :: [Time],
                               esNow :: Time
                             }
type Stats = Map String EventStats
type StatsAction = StateT EventStats IO ()

data Event = Ev Time String

newEventStats :: IO Stats
newEventStats
    = Map.fromList `liftM`
      forM ["Ping", "FindNode", "GetPeers", "AnnouncePeer"]
               (\name ->
                    do f <- openFile (name ++ ".data") WriteMode
                       return (name, EventStats { esFile = f,
                                                  esTimes = [],
                                                  esNow = 0
                                                })
               )

countEvent :: Stats -> Event -> IO Stats
countEvent stats (Ev time name)
    = case Map.lookup name stats of
        Just es ->
            do es' <- execStateT updateStats es
               return $ Map.insert name es' stats
        Nothing ->
            do putStrLn $ "No file for " ++ name
               return stats
    where updateStats :: StatsAction
          updateStats = do es <- get
                           put $ es { esTimes = esTimes es ++ [time] }
                           writeData
          writeData :: StatsAction
          writeData = do now <- esNow `liftM` get
                         when (now + 0.1 < time - 1.0) writeData'
          writeData' = do dropUntilNow
                          es <- get
                          let now = esNow es
                          eventCountNow <- length `liftM`
                                           filter (\time ->
                                                       time >= now - 0.5 && time < now + 0.5
                                                  ) `liftM`
                                           esTimes `liftM`
                                           get
                          liftIO $ hPutStrLn (esFile es) $ show now ++ " " ++ show eventCountNow
                          put $ es { esNow = now + 0.1 }
                          writeData
          dropUntilNow :: StatsAction
          dropUntilNow = do es <- get
                            put $ es { esTimes = dropWhile (< ((esNow es) - 0.5)) (esTimes es) }

lineToEvent s = let (timeS, 's':' ':s') = break (not . (`elem` '.':['0'..'9'])) s
                    time = read timeS
                    (name, _) = break (not . isAlpha) s'
                in Ev time name

relTime :: [Event] -> [Event]
relTime events@((Ev start _):_)
    = map (\(Ev time name) ->
               Ev (time - start) name
          ) events

main = do events <- relTime `liftM` map lineToEvent `liftM` lines `liftM` readFile "spoofer.log"
          stats <- newEventStats
          foldM_ countEvent stats events
