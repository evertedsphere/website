{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE DuplicateRecordFields #-}

module Main where

import           Control.Lens
import           Control.Monad
import           Data.Aeson                 as A
import           Data.Aeson.Lens
import           Data.Time
import           Development.Shake
import           Development.Shake.Classes
import           Development.Shake.Forward
import           Development.Shake.FilePath
import           GHC.Generics               (Generic)
import           Slick

import qualified Data.HashMap.Lazy as HML
import qualified Data.Text                  as T
import Data.Text                  (Text)

---Config-----------------------------------------------------------------------

siteMeta :: SiteMeta
siteMeta =
    SiteMeta { siteAuthor = "Swann Moreau"
             , baseUrl = "https://casuallyconsistent.com"
             , siteTitle = "casuallyconsistent"
             , twitterHandle = Just "evertedsphere"
             , githubUser = Just "evertedsphere"
             }

outputFolder :: FilePath
outputFolder = "dist/"

--Data models-------------------------------------------------------------------

withSiteMeta :: Value -> Value
withSiteMeta (Object obj) = Object $ HML.union obj siteMetaObj
  where
    Object siteMetaObj = toJSON siteMeta
withSiteMeta _ = error "only add site meta to objects"

data SiteMeta =
    SiteMeta { siteAuthor    :: Text
             , baseUrl       :: Text -- e.g. https://example.ca
             , siteTitle     :: Text
             , twitterHandle :: Maybe Text -- Without @
             , githubUser    :: Maybe Text
             }
    deriving (Generic, Eq, Ord, Show, ToJSON)

-- | Data for the index page
newtype IndexInfo =
  IndexInfo
    { posts :: [Post]
    } deriving (Generic, Show, FromJSON, ToJSON)

type Tag = Text

-- | Data for a blog post
data Post =
    Post { title       :: Text
         , author      :: Text
         , content     :: Text
         , url         :: Text
         , date        :: Text
         , tags        :: [Tag]
         , description :: Text
         , image       :: Maybe Text
         }
    deriving (Generic, Eq, Ord, Show, FromJSON, ToJSON, Binary)

data AtomData =
  AtomData { title        :: Text
           , domain       :: Text
           , author       :: Text
           , posts        :: [Post]
           , currentTime  :: Text
           , atomUrl      :: Text } deriving (Generic, ToJSON, Eq, Ord, Show)

-- | given a list of posts this will build a table of contents
buildIndex :: [Post] -> Action ()
buildIndex posts' = do
  indexT <- compileTemplate' "site/templates/index.html"
  let indexInfo = IndexInfo {posts = posts'}
      indexHTML = T.unpack $ substitute indexT (withSiteMeta $ toJSON indexInfo)
  writeFile' (outputFolder </> "index.html") indexHTML

-- | Find and build all posts
buildPosts :: Action [Post]
buildPosts = do
  pPaths <- getDirectoryFiles "." ["site/posts//*.md"]
  forP pPaths buildPost

-- | Load a post, process metadata, write it to output, then return the post object
-- Detects changes to either post content or template
buildPost :: FilePath -> Action Post
buildPost srcPath = cacheAction ("build" :: T.Text, srcPath) $ do
  liftIO . putStrLn $ "Rebuilding post: " <> srcPath
  postContent <- readFile' srcPath
  -- load post content and metadata as JSON blob
  postData <- markdownToHTML . T.pack $ postContent
  let postUrl = T.pack . dropDirectory1 $ srcPath -<.> "html"
      withPostUrl = _Object . at "url" ?~ String postUrl
  -- Add additional metadata we've been able to compute
  let fullPostData = withSiteMeta . withPostUrl $ postData
  template <- compileTemplate' "site/templates/post.html"
  writeFile' (outputFolder </> T.unpack postUrl) . T.unpack $ substitute template fullPostData
  convert fullPostData

-- | Copy all static files from the listed folders to their destination
copyStaticFiles :: Action ()
copyStaticFiles = do
    filepaths <- getDirectoryFiles "./site/" ["images//*", "css//*", "js//*"]
    void $ forP filepaths $ \filepath ->
        copyFileChanged ("site" </> filepath) (outputFolder </> filepath)

formatDate :: Text -> Text
formatDate humanDate = toIsoDate parsedTime
  where
    parsedTime =
      parseTimeOrError True defaultTimeLocale "%b %e, %Y" (T.unpack humanDate) :: UTCTime

rfc3339 :: Maybe Text
rfc3339 = Just "%H:%M:SZ"

toIsoDate :: UTCTime -> Text
toIsoDate = T.pack . formatTime defaultTimeLocale (iso8601DateFormat (T.unpack <$> rfc3339))

buildFeed :: [Post] -> Action ()
buildFeed posts = do
  now <- liftIO getCurrentTime
  let atomData =
        AtomData
          { title = siteTitle siteMeta
          , domain = baseUrl siteMeta
          , author = siteAuthor siteMeta
          , posts = mkAtomPost <$> posts
          , currentTime = toIsoDate now
          , atomUrl = "/atom.xml"
          }
  atomTempl <- compileTemplate' "site/templates/atom.xml"
  writeFile' (outputFolder </> "atom.xml") . T.unpack $ substitute atomTempl (toJSON atomData)
    where
      mkAtomPost :: Post -> Post
      mkAtomPost p = p { date = formatDate $ date p }

-- | Specific build rules for the Shake system
--   defines workflow to build the website
buildRules :: Action ()
buildRules = do
  allPosts <- buildPosts
  buildIndex allPosts
  buildFeed allPosts
  copyStaticFiles

main :: IO ()
main = do
  let shOpts = shakeOptions { shakeVerbosity = Chatty, shakeLintInside = ["\\"]}
  shakeArgsForward shOpts buildRules
