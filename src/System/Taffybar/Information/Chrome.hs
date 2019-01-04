{-# LANGUAGE OverloadedStrings #-}
module System.Taffybar.Information.Chrome where

import           Control.Concurrent
import           Control.Monad
import           Control.Monad.Trans.Class
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map as M
import           Data.Maybe
import qualified Data.Text as StrictText
import qualified GI.GLib as Gdk
import qualified GI.GdkPixbuf as Gdk
import           Prelude
import           System.Log.Logger
import           System.Taffybar.Context hiding (logIO, logT)
import           System.Taffybar.Information.EWMHDesktopInfo
import           System.Taffybar.Information.SafeX11
import           Text.Read hiding (lift)
import           Text.Regex
import           Web.Scotty

logIO :: System.Log.Logger.Priority -> String -> IO ()
logIO = logM "System.Taffybar.Information.Chrome"

data ChromeTabImageData = ChromeTabImageData
  { tabImageData :: Gdk.Pixbuf
  , tabImageDataId :: Int
  }

newtype ChromeTabImageDataState =
  ChromeTabImageDataState
  (MVar (M.Map Int ChromeTabImageData), Chan ChromeTabImageData)

getChromeTabImageDataState :: TaffyIO ChromeTabImageDataState
getChromeTabImageDataState =
  getStateDefault listenForChromeFaviconUpdates

getChromeTabImageDataChannel :: TaffyIO (Chan ChromeTabImageData)
getChromeTabImageDataChannel = do
  ChromeTabImageDataState (_, chan) <- getChromeTabImageDataState
  return chan

getChromeTabImageDataTable :: TaffyIO (MVar (M.Map Int ChromeTabImageData))
getChromeTabImageDataTable = do
  ChromeTabImageDataState (table, _) <- getChromeTabImageDataState
  return table

newtype ChromeFaviconServerPort = ChromeFaviconServerPort Int

listenForChromeFaviconUpdates :: TaffyIO ChromeTabImageDataState
listenForChromeFaviconUpdates = do
  infoVar <- lift $ newMVar M.empty
  chan <- lift newChan
  ChromeFaviconServerPort port <- getStateDefault (return $ ChromeFaviconServerPort 5000)
  _ <- lift $ forkIO $ scotty port $
    post "/setTabImageData/:tabID" $ do
      tabID <- param "tabID"
      lazyImageData <- body
      let imageData = LBS.toStrict lazyImageData
      when (BS.length imageData > 0) $ lift $ do
        loader <- Gdk.pixbufLoaderNew
        bytesData <- Gdk.bytesNew $ Just imageData
        Gdk.pixbufLoaderWriteBytes loader bytesData
        Gdk.pixbufLoaderClose loader
        pixbuf <- Gdk.pixbufLoaderGetPixbuf loader
        let chromeTabImageData =
              ChromeTabImageData
              { tabImageData = pixbuf
              , tabImageDataId = tabID
              }
        modifyMVar_ infoVar $ \currentMap -> do
          writeChan chan chromeTabImageData
          return $ M.insert tabID chromeTabImageData currentMap
  return $ ChromeTabImageDataState (infoVar, chan)

newtype X11WindowToChromeTabId = X11WindowToChromeTabId (MVar (M.Map X11Window Int))

getX11WindowToChromeTabId :: TaffyIO X11WindowToChromeTabId
getX11WindowToChromeTabId =
  getStateDefault $ X11WindowToChromeTabId <$> maintainX11WindowToChromeTabId

maintainX11WindowToChromeTabId :: TaffyIO (MVar (M.Map X11Window Int))
maintainX11WindowToChromeTabId = do
  startTabMap <- updateTabMap M.empty
  tabMapVar <- lift $ newMVar startTabMap
  let handleEvent PropertyEvent { ev_window = window } =
        do
          title <- runX11Def "" $ getWindowTitle window
          lift $ modifyMVar_ tabMapVar $ \currentMap -> do
            let newMap = addTabIdEntry currentMap (window, title)
            logIO DEBUG (show newMap)
            return newMap
      handleEvent _ = return ()
  subscribeToEvents ["_NET_WM_NAME"] handleEvent
  return tabMapVar

tabIDRegex :: Regex
tabIDRegex = mkRegexWithOpts "[|]%([0-9]*)%[|]" True True

getTabIdFromTitle :: String -> Maybe Int
getTabIdFromTitle title =
  matchRegex tabIDRegex title >>= listToMaybe >>= readMaybe

addTabIdEntry :: M.Map X11Window Int -> (X11Window, String) -> M.Map X11Window Int
addTabIdEntry theMap (win, title) =
          maybe theMap ((flip $ M.insert win) theMap) $ getTabIdFromTitle title

updateTabMap :: M.Map X11Window Int -> TaffyIO (M.Map X11Window Int)
updateTabMap tabMap =
  runX11Def tabMap $ do
    wins <- getWindows
    titles <- mapM getWindowTitle wins
    let winsWithTitles = zip wins titles
    return $ foldl addTabIdEntry tabMap winsWithTitles