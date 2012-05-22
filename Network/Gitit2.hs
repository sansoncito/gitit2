{-# LANGUAGE TypeFamilies, QuasiQuotes, MultiParamTypeClasses,
             TemplateHaskell, OverloadedStrings, FlexibleInstances,
             ScopedTypeVariables #-}
module Network.Gitit2 ( GititConfig (..)
                      , Page (..)
                      , Dir (..)
                      , HasGitit (..)
                      , Gitit (..)
                      , GititUser (..)
                      , GititMessage (..)
                      , Route (..)
                      , Tab (..)
                      , PageLayout (..)
                      , pageLayout
                      , makeDefaultPage
                      ) where

import Prelude hiding (catch)
import Yesod hiding (MsgDelete)
import Yesod.Static
import Yesod.Default.Handlers -- robots, favicon
import Language.Haskell.TH hiding (dyn)
import Data.List (inits)
import Data.FileStore as FS
import System.FilePath
import Text.Pandoc
import Text.Pandoc.Shared (stringify)
import Control.Applicative
import Control.Monad (when, filterM)
import qualified Data.Text as T
import Data.Text (Text)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy.UTF8 (toString)
import Text.Blaze.Html hiding (contents)
import Text.HTML.SanitizeXSS (sanitizeAttribute)
import Data.Monoid (Monoid, mappend)
import Data.Maybe (mapMaybe)
import System.Random (randomRIO)
import Control.Exception (throw, handle, try)

-- This is defined in GHC 7.04+, but for compatibility we define it here.
infixr 5 <>
(<>) :: Monoid m => m -> m -> m
(<>) = mappend

-- | A Gitit wiki.  For an example of how a Gitit subsite
-- can be integrated into another Yesod app, see @src/gitit.hs@
-- in the package source.
data Gitit = Gitit{ config        :: GititConfig  -- ^ Wiki config options.
                  , filestore     :: FileStore    -- ^ Filestore with pages.
                  , getStatic     :: Static       -- ^ Static subsite.
                  }

instance Yesod Gitit

-- | Configuration for a gitit wiki.
data GititConfig = GititConfig{
       wiki_path  :: FilePath    -- ^ Path to the repository.
     }

-- | Path to a wiki page.  Pages can't begin with '_'.
data Page = Page Text deriving (Show, Read, Eq)

-- for now, we disallow @*@ and @?@ in page names, because git filestore
-- does not deal with them properly, and darcs filestore disallows them.
instance PathMultiPiece Page where
  toPathMultiPiece (Page x) = T.splitOn "/" x
  fromPathMultiPiece (x:xs) = if "_" `T.isPrefixOf` x ||
                                 "*" `T.isInfixOf` x ||
                                 "?" `T.isInfixOf` x ||
                                 ".." `T.isInfixOf` x ||
                                 "/_" `T.isInfixOf` x
                                 then Nothing
                                 else Just (Page $ T.intercalate "/" $ x:xs)
  fromPathMultiPiece []     = Nothing

instance ToMarkup Page where
  toMarkup (Page x) = toMarkup x

instance ToMessage Page where
  toMessage (Page x) = x

instance ToMarkup (Maybe Page) where
  toMarkup (Just x) = toMarkup x
  toMarkup Nothing  = ""

-- | Wiki directory.  Directories can't begin with '_'.
data Dir = Dir Text deriving (Show, Read, Eq)

instance PathMultiPiece Dir where
  toPathMultiPiece (Dir x) = T.splitOn "/" x
  fromPathMultiPiece (x:xs) = if "_" `T.isPrefixOf` x
                              then Nothing
                              else Just (Dir $ T.intercalate "/" $ x:xs)
  fromPathMultiPiece []     = Just $ Dir ""

instance ToMarkup Dir where
  toMarkup (Dir x) = toMarkup x

instance ToMessage Dir where
  toMessage (Dir x) = x

-- | A user.
data GititUser = GititUser{ gititUserName  :: String
                          , gititUserEmail :: String
                          } deriving Show

-- | A tab in the page layout.
data Tab  = ViewTab
          | EditTab
          | HistoryTab
          | DiscussTab
          | DiffTab
          deriving (Eq, Show)

-- | Page layout.
data PageLayout = PageLayout{
    pgName           :: Maybe Page
  , pgRevision       :: Maybe String
  , pgPrintable      :: Bool
  , pgPageTools      :: Bool
  , pgSiteNav        :: Bool
  , pgTabs           :: [Tab]
  , pgSelectedTab    :: Tab
  }

-- | Default page layout.
pageLayout :: PageLayout
pageLayout = PageLayout{
    pgName           = Nothing
  , pgRevision       = Nothing
  , pgPrintable      = False
  , pgPageTools      = False
  , pgSiteNav        = True
  , pgTabs           = []
  , pgSelectedTab    = ViewTab
  }

-- Create GititMessages.
mkMessage "Gitit" "messages" "en"

-- | The master site containing a Gitit subsite must be an instance
-- of this typeclass.
-- TODO: replace the user functions with isAuthorized from Yesod typeclass?
class (Yesod master, RenderMessage master FormMessage,
       RenderMessage master GititMessage) => HasGitit master where
  -- | Return user information, if user is logged in, or nothing.
  maybeUser   :: GHandler sub master (Maybe GititUser)
  -- | Return user information or redirect to login page.
  requireUser :: GHandler sub master GititUser
  -- | Gitit subsite page layout.
  makePage :: PageLayout -> GWidget Gitit master () -> GHandler Gitit master RepHtml

-- Create routes.
mkYesodSub "Gitit" [ ClassP ''HasGitit [VarT $ mkName "master"]
 ] [parseRoutesNoCheck|
/ HomeR GET
/_help HelpR GET
/_static StaticR Static getStatic
/_index/*Dir  IndexR GET
/favicon.ico FaviconR GET
/robots.txt RobotsR GET
/_random RandomR GET
/_raw/*Page RawR GET
/_edit/*Page  EditR GET
/_revision/#RevisionId/*Page RevisionR GET
/_revert/#RevisionId/*Page RevertR GET
/_update/#RevisionId/*Page UpdateR POST
/_create/*Page CreateR POST
/_delete/*Page DeleteR GET POST
/*Page     ViewR GET
|]

makeDefaultPage :: HasGitit master => PageLayout -> GWidget Gitit master () -> GHandler Gitit master RepHtml
makeDefaultPage layout content = do
  toMaster <- getRouteToMaster
  let logoRoute = toMaster $ StaticR $ StaticRoute ["img","logo.png"] []
  let feedRoute = toMaster $ StaticR $ StaticRoute ["img","icons","feed.png"] []
  let tabClass :: Tab -> Text
      tabClass t = if t == pgSelectedTab layout then "selected" else ""
  let showTab t = t `elem` pgTabs layout
  printLayout <- lookupGetParam "print"
  defaultLayout $ do
    addStylesheet $ toMaster $ StaticR $
      case printLayout of
           Just _  -> StaticRoute ["css","print.css"] []
           Nothing -> StaticRoute ["css","custom.css"] []
    addScript $ toMaster $ StaticR $ StaticRoute ["js","jquery-1.7.2.min.js"] []
    toWidget $ [lucius|input.hidden { display: none; } |]
    [whamlet|
    <div #doc3 .yui-t1>
      <div #yui-main>
        <div #maincol .yui-b>
          <div #userbox>
          $maybe page <- pgName layout
            <ul .tabs>
              $if showTab ViewTab
                <li class=#{tabClass ViewTab}>
                  <a href=@{toMaster $ ViewR page}>_{MsgView}</a>
              $if showTab EditTab
                <li class=#{tabClass EditTab}>
                  <a href=@{toMaster $ EditR page}>_{MsgEdit}</a>
              $if showTab HistoryTab
                <li class=#{tabClass HistoryTab}>
                  <a href="">_{MsgHistory}</a>
              $if showTab DiscussTab
                <li class=#{tabClass DiscussTab}
                  ><a href="">_{MsgDiscuss}</a>
          <div #content>
            ^{content}
      <div #sidebar .yui-b .first>
        <div #logo>
          <a href=@{toMaster HomeR}><img src=@{logoRoute} alt=logo></a>
        $if pgSiteNav layout
          <div .sitenav>
            <fieldset>
              <legend>Site
              <ul>
                <li><a href=@{toMaster HomeR}>_{MsgFrontPage}</a>
                <li><a href=@{toMaster $ IndexR $ Dir ""}>_{MsgDirectory}</a>
                <li><a href="">_{MsgCategories}</a>
                <li><a href=@{toMaster $ RandomR}>_{MsgRandomPage}</a>
                <li><a href="">_{MsgRecentActivity}</a>
                <li><a href="">_{MsgUploadFile}</a></li>
                <li><a href="" type="application/atom+xml" rel="alternate" title="ATOM Feed">_{MsgAtomFeed}</a> <img alt="feed icon" src=@{feedRoute}>
                <li><a href=@{toMaster HelpR}>_{MsgHelp}</a></li>
              <form action="" method="post" id="searchform">
               <input type="text" name="patterns" id="patterns">
               <input type="submit" name="search" id="search" value="_{MsgSearch}">
              <form action="" method="post" id="goform">
                <input type="text" name="gotopage" id="gotopage">
                <input type="submit" name="go" id="go" value="_{MsgGo}">
        $if pgPageTools layout
          <div .pagetools>
            $maybe page <- pgName layout
              <fieldset>
                <legend>This page</legend>
                <ul>
                  <li><a href=@{toMaster $ RawR page}>_{MsgRawPageSource}</a>
                  <li><a href="@{toMaster $ ViewR page}?print">_{MsgPrintableVersion}</a>
                  <li><a href=@{toMaster $ DeleteR page}>_{MsgDeleteThisPage}</a>
                  <li><a href="" type="application/atom+xml" rel="alternate" title="This page's ATOM Feed">_{MsgAtomFeed}</a> <img alt="feed icon" src=@{feedRoute}>
                <!-- TODO exports here -->
  |]

-- HANDLERS and utility functions, not exported:

-- | Convert links with no URL to wikilinks.
convertWikiLinks :: Inline -> GHandler Gitit master Inline
convertWikiLinks (Link ref ("", "")) = do
  toMaster <- getRouteToMaster
  toUrl <- getUrlRender
  let route = ViewR $ Page $ T.pack $ stringify ref
  return $ Link ref (T.unpack $ toUrl $ toMaster route, "")
convertWikiLinks x = return x

addWikiLinks :: Pandoc -> GHandler Gitit master Pandoc
addWikiLinks = bottomUpM convertWikiLinks

sanitizePandoc :: Pandoc -> Pandoc
sanitizePandoc = bottomUp sanitizeBlock . bottomUp sanitizeInline
  where sanitizeBlock (RawBlock _ _) = Text.Pandoc.Null
        sanitizeBlock (CodeBlock (id',classes,attrs) x) =
          CodeBlock (id', classes, sanitizeAttrs attrs) x
        sanitizeBlock x = x
        sanitizeInline (RawInline _ _) = Str ""
        sanitizeInline (Code (id',classes,attrs) x) =
          Code (id', classes, sanitizeAttrs attrs) x
        sanitizeInline (Link lab (src,tit)) = Link lab (sanitizeURI src,tit)
        sanitizeInline (Image alt (src,tit)) = Link alt (sanitizeURI src,tit)
        sanitizeInline x = x
        sanitizeURI src = case sanitizeAttribute ("href", T.pack src) of
                               Just (_,z) -> T.unpack z
                               Nothing    -> ""
        sanitizeAttrs = mapMaybe sanitizeAttr
        sanitizeAttr (x,y) = case sanitizeAttribute (T.pack x, T.pack y) of
                                  Just (w,z) -> Just (T.unpack w, T.unpack z)
                                  Nothing    -> Nothing

pathForPage :: Page -> GHandler Gitit master FilePath
pathForPage (Page page) = return $ T.unpack page <.> "page"

pathForFile :: Page -> GHandler Gitit master FilePath
pathForFile (Page page) = return $ T.unpack page

pageForPath :: FilePath -> GHandler Gitit master Page
pageForPath fp = return $ Page $ T.pack $
  if takeExtension fp == ".page"
     then dropExtension fp
     else fp

isDiscussPage :: Page -> Bool
isDiscussPage (Page x) = "@" `T.isPrefixOf` x

isPageFile :: FilePath -> GHandler Gitit master Bool
isPageFile f = return $ takeExtension f == ".page"

isDiscussPageFile :: FilePath -> GHandler Gitit master Bool
isDiscussPageFile ('@':xs) = isPageFile xs
isDiscussPageFile _ = return False

-- TODO : make the front page configurable
getHomeR :: HasGitit master => GHandler Gitit master RepHtml
getHomeR = getViewR (Page "Front Page")

-- TODO : make the help page configurable
getHelpR :: HasGitit master => GHandler Gitit master RepHtml
getHelpR = getViewR (Page "Help")

getRandomR :: HasGitit master => GHandler Gitit master RepHtml
getRandomR = do
  fs <- filestore <$> getYesodSub
  files <- liftIO $ index fs
  pages <- mapM pageForPath =<< filterM (fmap not . isDiscussPageFile)
                            =<<filterM isPageFile files
  pagenum <- liftIO $ randomRIO (0, length pages - 1)
  let thepage = pages !! pagenum
  toMaster <- getRouteToMaster
  redirect $ toMaster $ ViewR thepage

getRawR :: HasGitit master => Page -> GHandler Gitit master RepPlain
getRawR page = do
  mbcont <- getRawContents page Nothing
  case mbcont of
       Nothing       -> notFound
       Just (_,cont) -> return $ RepPlain $ toContent cont

getDeleteR :: HasGitit master => Page -> GHandler Gitit master RepHtml
getDeleteR page = do
  requireUser
  fs <- filestore <$> getYesodSub
  path <- pathForPage page
  pageTest <- liftIO $ try $ latest fs path
  fileToDelete <- case pageTest of
                       Right _        -> return path
                       Left  FS.NotFound -> do
                         path' <- pathForFile page
                         fileTest <- liftIO $ try $ latest fs path'
                         case fileTest of
                              Right _     -> return path' -- a file
                              Left FS.NotFound  -> fail (show FS.NotFound)
                              Left e      -> fail (show e)
                       Left e        -> fail (show e)
  toMaster <- getRouteToMaster
  makePage pageLayout{ pgName = Just page
                     , pgTabs = []
                     } $ do
    [whamlet|
      <h1>#{page}</h1>
      <div #deleteform>
        <form method=post action=@{toMaster $ DeleteR page}>
          <p>_{MsgConfirmDelete page}
          <input type=text class=hidden name=fileToDelete value=#{fileToDelete}>
          <input type=submit value=_{MsgDelete}>
    |]

postDeleteR :: HasGitit master => Page -> GHandler Gitit master RepHtml
postDeleteR page = do
  user <- requireUser
  fs <- filestore <$> getYesodSub
  toMaster <- getRouteToMaster
  mr <- getMessageRender
  fileToDelete <- runInputPost $ ireq textField "fileToDelete"
  liftIO $ FS.delete fs (T.unpack fileToDelete)
            (Author (gititUserName user) (gititUserEmail user))
            (T.unpack $ mr $ MsgDeleted page)
  setMessageI $ MsgDeleted page
  redirect (toMaster HomeR)

getViewR :: HasGitit master => Page -> GHandler Gitit master RepHtml
getViewR = view Nothing

getRevisionR :: HasGitit master => RevisionId -> Page -> GHandler Gitit master RepHtml
getRevisionR rev = view (Just rev)

view :: HasGitit master => Maybe RevisionId -> Page -> GHandler Gitit master RepHtml
view mbrev page = do
  toMaster <- getRouteToMaster
  mbcont <- getRawContents page mbrev
  case mbcont of
       Nothing    -> do setMessageI (MsgNewPage page)
                        redirect (toMaster $ EditR page)
       Just (_,contents) -> do
           htmlContents <- contentsToHtml contents
           makePage pageLayout{ pgName = Just page
                              , pgPageTools = True
                              , pgTabs = [ViewTab,EditTab,HistoryTab,DiscussTab]
                              , pgSelectedTab = ViewTab } $
                    do setTitle $ toMarkup page
                       [whamlet|
                         <h1 .title>#{page}
                         $maybe rev <- mbrev
                           <h2 .revision>#{rev}
                         ^{toWikiPage htmlContents}
                       |]

getIndexR :: HasGitit master => Dir -> GHandler Gitit master RepHtml
getIndexR (Dir dir) = do
  fs <- filestore <$> getYesodSub
  listing <- liftIO $ directory fs $ T.unpack dir
  let isDiscussionPage (FSFile f) = isDiscussPageFile f
      isDiscussionPage (FSDirectory _) = return False
  prunedListing <- filterM (fmap not . isDiscussionPage) listing
  let updirs = inits $ filter (not . T.null) $ toPathMultiPiece (Dir dir)
  toMaster <- getRouteToMaster
  let pref = if T.null dir
                then id
                else \x -> dir <> "/" <> x
  let process (FSFile f) = do
        Page page <- pageForPath f
        ispage <- isPageFile f
        let route = toMaster $ ViewR $ Page $ pref page
        return (if ispage then ("page" :: Text) else "upload", route, page)
      process (FSDirectory f) = do
        Page page <- pageForPath f
        let route = toMaster $ IndexR $ Dir $ pref page
        return ("folder", route, page)
  entries <- mapM process prunedListing
  makePage pageLayout{ pgName = Nothing } $ [whamlet|
    <h1 .title>
      $forall up <- updirs
        ^{upDir toMaster up}
    <div .index>
      <ul>
        $forall (cls,route,name) <- entries
          <li .#{cls}>
            <a href=@{route}>#{name}</a>
  |]

upDir :: (Route Gitit -> Route master) -> [Text] -> GWidget Gitit master ()
upDir toMaster fs = do
  let lastdir = case reverse fs of
                     (f:_)  -> f
                     []     -> "\x2302"
  [whamlet|<a href=@{toMaster $ IndexR $ maybe (Dir "") id $ fromPathMultiPiece fs}>#{lastdir}/</a>|]

getRawContents :: HasGitit master => Page -> Maybe RevisionId -> GHandler Gitit master (Maybe (RevisionId, ByteString))
getRawContents page rev = do
  fs <- filestore <$> getYesodSub
  path <- pathForPage page
  liftIO $ handle (\e -> if e == FS.NotFound then return Nothing else throw e)
         $ do revid <- latest fs path
              cont <- retrieve fs path rev
              return $ Just (revid, cont)

contentsToHtml :: HasGitit master => ByteString -> GHandler Gitit master Html
contentsToHtml contents = do
  let doc = readMarkdown defaultParserState{ stateSmart = True } $ toString contents
  doc' <- sanitizePandoc <$> addWikiLinks doc
  let rendered = writeHtml defaultWriterOptions{
                     writerWrapText = False
                   , writerHtml5 = True
                   , writerHighlight = True
                   , writerHTMLMathMethod = MathJax $ T.unpack mathjax_url } doc'
  return rendered

-- TODO replace with something in configuration.
mathjax_url :: Text
mathjax_url = "https://d3eoax9i5htok0.cloudfront.net/mathjax/latest/MathJax.js?config=TeX-AMS-MML_HTMLorMML"

toWikiPage :: HasGitit master => Html -> GWidget Gitit master ()
toWikiPage rendered = do
  addScriptRemote mathjax_url
  toWidget rendered

getEditR :: HasGitit master => Page -> GHandler Gitit master RepHtml
getEditR page = do
  requireUser
  mbcont <- getRawContents page Nothing
  let contents = case mbcont of
                       Nothing    -> ""
                       Just (_,c) -> toString c
  let mbrev = maybe Nothing (Just . fst) mbcont
  edit False contents mbrev page

getRevertR :: HasGitit master
           => RevisionId -> Page -> GHandler Gitit master RepHtml
getRevertR rev page = do
  requireUser
  mbcont <- getRawContents page (Just rev)
  case mbcont of
       Nothing           -> notFound
       Just (r,contents) -> edit True (toString contents) (Just r) page

edit :: HasGitit master
     => Bool               -- revert?
     -> String             -- contents to put in text box
     -> Maybe RevisionId   -- unless new page, Just id of old version
     -> Page
     -> GHandler Gitit master RepHtml
edit revert text mbrevid page = do
  requireUser
  let contents = Textarea $ T.pack $ text
  mr <- getMessageRender
  let comment = if revert
                   then mr $ MsgReverted $ maybe "" id mbrevid
                   else ""
  (form, enctype) <- generateFormPost $ editForm
                     $ Just Edit{ editContents = contents
                                , editComment = comment }
  toMaster <- getRouteToMaster
  let route = toMaster $ case mbrevid of
                    Just revid -> UpdateR revid page
                    Nothing    -> CreateR page
  showEditForm page route enctype $ do
    when revert $ toWidget [julius|
       $(document).ready(function (){
          $('textarea').attr('readonly','readonly').attr('style','color: gray;');
          }); |]
    form

showEditForm :: HasGitit master
             => Page
             -> Route master
             -> Enctype
             -> GWidget Gitit master ()
             -> GHandler Gitit master RepHtml
showEditForm page route enctype form = do
  makePage pageLayout{ pgName = Just page
                     , pgTabs = [ViewTab,EditTab,HistoryTab,DiscussTab]
                     , pgSelectedTab = EditTab } $ do
    [whamlet|
      <h1>#{page}</h1>
      <div #editform>
        <form method=post action=@{route} enctype=#{enctype}>
          ^{form}
          <input type=submit>
    |]

postUpdateR :: HasGitit master
          => RevisionId -> Page -> GHandler Gitit master RepHtml
postUpdateR revid page = update' (Just revid) page

postCreateR :: HasGitit master
            => Page -> GHandler Gitit master RepHtml
postCreateR page = update' Nothing page

update' :: HasGitit master
       => Maybe RevisionId -> Page -> GHandler Gitit master RepHtml
update' mbrevid page = do
  user <- requireUser
  ((result, widget), enctype) <- runFormPost $ editForm Nothing
  fs <- filestore <$> getYesodSub
  toMaster <- getRouteToMaster
  let route = toMaster $ case mbrevid of
                  Just revid  -> UpdateR revid page
                  Nothing     -> CreateR page
  case result of
       FormSuccess r -> do
         let auth = Author (gititUserName user) (gititUserEmail user)
         let comm = T.unpack $ editComment r
         let cont = filter (/='\r') $ T.unpack $ unTextarea $ editContents r
         path <- pathForPage page
         case mbrevid of
           Just revid -> do
              mres <- liftIO $ modify fs path revid auth comm cont
              case mres of
                   Right () -> redirect $ toMaster $ ViewR page
                   Left mergeinfo -> do
                      setMessageI $ MsgMerged revid
                      edit False (mergeText mergeinfo)
                           (Just $ revId $ mergeRevision mergeinfo) page
           Nothing -> do
             liftIO $ save fs path auth comm cont
             redirect $ toMaster $ ViewR page
       _ -> showEditForm page route enctype widget

data Edit = Edit { editContents :: Textarea
                 , editComment  :: Text
                 } deriving Show

editForm :: HasGitit master
         => Maybe Edit
         -> Html
         -> MForm Gitit master (FormResult Edit, GWidget Gitit master ())
editForm mbedit = renderDivs $ Edit
    <$> areq textareaField (fieldSettingsLabel MsgPageSource)
           (editContents <$> mbedit)
    <*> areq commentField (fieldSettingsLabel MsgChangeDescription)
           (editComment <$> mbedit)
  where commentField = check validateNonempty textField
        validateNonempty y
          | T.null y = Left MsgValueRequired
          | otherwise = Right y
