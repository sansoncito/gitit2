{-# LANGUAGE QuasiQuotes, TemplateHaskell, MultiParamTypeClasses, TypeFamilies,
    OverloadedStrings #-}
import Network.Gitit2
import Network.Socket hiding (Debug)
import Yesod
import Yesod.Static
import Network.Wai.Handler.Warp
import Data.FileStore
import Data.Char
import Data.Yaml
import Control.Applicative
import qualified Data.ByteString.Char8 as B
import qualified Data.Map as M
import System.IO
import System.Exit

data Master = Master { getGitit :: Gitit }
mkYesod "Master" [parseRoutes|
/ SubsiteR Gitit getGitit
|]

instance Yesod Master where
  defaultLayout contents = do
    PageContent title headTags bodyTags <- widgetToPageContent $ do
      addWidget contents
    mmsg <- getMessage
    hamletToRepHtml [hamlet|
        $doctype 5
        <html>
          <head>
             <title>#{title}
             ^{headTags}
          <body>
             $maybe msg  <- mmsg
               <p.message>#{msg}
             ^{bodyTags}
        |]

instance RenderMessage Master FormMessage where
    renderMessage _ _ = defaultFormMessage

instance RenderMessage Master GititMessage where
    renderMessage x = renderMessage (getGitit x)

instance HasGitit Master where
  maybeUser = return $ Just $ GititUser "Dummy" "dumb@dumber.org"
  requireUser = return $ GititUser "Dummy" "dumb@dumber.org"
  makePage = makeDefaultPage

-- | Ready collection of common mime types. (Copied from
-- Happstack.Server.HTTP.FileServe.)
mimeTypes :: M.Map String ContentType
mimeTypes = M.fromList
        [("xml","application/xml")
        ,("xsl","application/xml")
        ,("js","text/javascript")
        ,("html","text/html")
        ,("htm","text/html")
        ,("css","text/css")
        ,("gif","image/gif")
        ,("jpg","image/jpeg")
        ,("png","image/png")
        ,("txt","text/plain; charset=UTF-8")
        ,("doc","application/msword")
        ,("exe","application/octet-stream")
        ,("pdf","application/pdf")
        ,("zip","application/zip")
        ,("gz","application/x-gzip")
        ,("ps","application/postscript")
        ,("rtf","application/rtf")
        ,("wav","application/x-wav")
        ,("hs","text/plain")]

data Conf = Conf { cfg_port            :: Int
                 , cfg_listen_address  :: String
                 , cfg_wiki_path       :: FilePath
                 , cfg_static_dir      :: FilePath
                 , cfg_mime_types_file :: Maybe FilePath
                 , cfg_html_math       :: String
                 , cfg_feed_days       :: Int
                 }

-- | Read a file associating mime types with extensions, and return a
-- map from extensions to types. Each line of the file consists of a
-- mime type, followed by space, followed by a list of zero or more
-- extensions, separated by spaces. Example: text/plain txt text
readMimeTypesFile :: FilePath -> IO (M.Map String ContentType)
readMimeTypesFile f = catch
  ((foldr go M.empty . map words . lines) `fmap` readFile f)
  handleMimeTypesFileNotFound
     where go []     m = m  -- skip blank lines
           go (x:xs) m = foldr (\ext -> M.insert ext $ B.pack x) m xs
           handleMimeTypesFileNotFound e = do
             warn $ "Could not parse mime types file.\n" ++ show e
             return mimeTypes

parseConfig :: Object -> Parser Conf
parseConfig o = Conf
  <$> o .:? "port" .!= 3000
  <*> o .:? "listen_address" .!= "0.0.0.0"
  <*> o .:? "wiki_path" .!= "wikidata"
  <*> o .:? "static_dir" .!= "static"
  <*> o .:? "mime_types_file"
  <*> o .:? "html_math" .!= "mathml"
  <*> o .:? "feed_days" .!= 14

err :: Int -> String -> IO a
err code msg = do
  hPutStrLn stderr msg
  exitWith $ ExitFailure code
  return undefined

warn :: String -> IO ()
warn msg = hPutStrLn stderr msg

main :: IO ()
main = do
  res <- decodeEither `fmap` B.readFile "config/settings.yaml"
  conf <- case res of
             Left e  -> err 3 $ "Error reading configuration file.\n" ++ e
             Right x -> parseMonad parseConfig x
  let fs = gitFileStore $ cfg_wiki_path conf
  st <- staticDevel $ cfg_static_dir conf
  mimes <- case cfg_mime_types_file conf of
                Nothing -> return mimeTypes
                Just f  -> readMimeTypesFile f
  math_method <- case map toLower (cfg_html_math conf) of
                        "mathml"  -> return UseMathML
                        "mathjax" -> return UseMathJax
                        "rawtex"  -> return UseRawTeX
                        _         -> err 5 $ "Unknown math method: " ++
                                              cfg_html_math conf

  -- open the requested interface
  sock <- socket AF_INET Stream defaultProtocol
  setSocketOption sock ReuseAddr 1
  device <- inet_addr $ cfg_listen_address conf
  bindSocket sock $ SockAddrInet (toEnum (cfg_port conf)) device
  listen sock 10

  let settings = defaultSettings{ settingsPort = cfg_port conf }
  let runner = runSettingsSocket settings sock
  runner =<< toWaiApp
      (Master (Gitit{ config    = GititConfig{
                                    mime_types = mimes
                                  , html_math  = math_method
                                  , feed_days  = cfg_feed_days conf
                                  }
                    , filestore = fs
                    , getStatic = st
                    }))
