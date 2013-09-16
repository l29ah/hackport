module Portage.EBuild
        ( EBuild(..)
        , ebuildTemplate
        , src_uri
        ) where

import Distribution.Text ( Text(..) )
import qualified Text.PrettyPrint as Disp

import Portage.Dependency

import Data.String.Utils
import qualified Data.Function as F
import qualified Data.List as L
import Data.Version(Version(..))
import qualified Paths_hackport(version)

data EBuild = EBuild {
    name :: String,
    hackage_name :: String, -- might differ a bit (we mangle case)
    version :: String,
    hackportVersion :: String,
    description :: String,
    long_desc :: String,
    homepage :: String,
    license :: Either String String,
    slot :: String,
    keywords :: [String],
    iuse :: [String],
    depend :: [Dependency],
    depend_extra :: [String],
    rdepend :: [Dependency],
    rdepend_extra :: [String],
    features :: [String],
    my_pn :: Maybe String -- ^ Just 'myOldName' if the package name contains upper characters
    , src_prepare :: [String] -- ^ raw block for src_prepare() contents
    , src_configure :: [String] -- ^ raw block for src_configure() contents
  }

getHackportVersion :: Version -> String
getHackportVersion Version {versionBranch=(x:s)} = foldl (\y z -> y ++ "." ++ (show z)) (show x) s
getHackportVersion Version {versionBranch=[]} = ""

ebuildTemplate :: EBuild
ebuildTemplate = EBuild {
    name = "foobar",
    hackage_name = "FooBar",
    version = "0.1",
    hackportVersion = getHackportVersion Paths_hackport.version,
    description = "",
    long_desc = "",
    homepage = "http://hackage.haskell.org/package/${HACKAGE_N}",
    license = Left "unassigned license?",
    slot = "0",
    keywords = ["~amd64","~x86"],
    iuse = [],
    depend = [],
    depend_extra = [],
    rdepend = [],
    rdepend_extra = [],
    features = [],
    my_pn = Nothing
    , src_prepare = []
    , src_configure = []
  }

instance Text EBuild where
  disp = Disp.text . showEBuild

-- | Given an EBuild, give the URI to the tarball of the source code.
-- Assumes that the server is always hackage.haskell.org.
src_uri :: EBuild -> String
src_uri e = 
  case my_pn e of
    -- use standard address given that the package name has no upper
    -- characters
    Nothing -> "http://hackage.haskell.org/packages/archive/${PN}/${PV}/${P}.tar.gz"
    -- use MY_X variables (defined in showEBuild) as we've renamed the
    -- package
    Just _  -> "http://hackage.haskell.org/packages/archive/${MY_PN}/${PV}/${MY_P}.tar.gz"

showEBuild :: EBuild -> String
showEBuild ebuild =
  ss "# Copyright 1999-2013 Gentoo Foundation". nl.
  ss "# Distributed under the terms of the GNU General Public License v2". nl.
  ss "# $Header: $". nl.
  nl.
  ss "EAPI=5". nl.
  nl.
  ss ("# ebuild generated by hackport " ++ hackportVersion ebuild). nl.
  nl.
  ss "CABAL_FEATURES=". quote' (sepBy " " $ features ebuild). nl.
  ss "inherit haskell-cabal". nl.
  nl.
  (case my_pn ebuild of
     Nothing -> id
     Just pn -> ss "MY_PN=". quote pn. nl.
                ss "MY_P=". quote "${MY_PN}-${PV}". nl. nl).
  ss "DESCRIPTION=". quote (description ebuild). nl.
  ss "HOMEPAGE=". quote (expandVars (homepage ebuild)). nl.
  ss "SRC_URI=". quote (toMirror $ src_uri ebuild). nl.
  nl.
  ss "LICENSE=". (either (\err -> quote "" . ss ("\t# FIXME: " ++ err))
                         quote
                         (license ebuild)). nl.
  ss "SLOT=". quote (slot ebuild). nl.
  ss "KEYWORDS=". quote' (sepBy " " $ keywords ebuild).nl.
  ss "IUSE=". quote' (sepBy " " . sort_iuse $ iuse ebuild). nl.
  nl.
  dep_str "RDEPEND" (rdepend_extra ebuild) (rdepend ebuild).
  dep_str "DEPEND"  ( depend_extra ebuild) ( depend ebuild).
  (case my_pn ebuild of
     Nothing -> id
     Just _ -> nl. ss "S=". quote ("${WORKDIR}/${MY_P}"). nl).
  verbatim (nl. ss "src_prepare() {" . nl)
               (src_prepare ebuild)
           (ss "}" . nl).
  verbatim (nl. ss "src_configure() {" . nl)
               (src_configure ebuild)
           (ss "}" . nl).
  id $ []
  where
        expandVars = replaceMultiVars [ (        name ebuild, "${PN}")
                                      , (hackage_name ebuild, "${HACKAGE_N}")
                                      ]
        toMirror = replace "http://hackage.haskell.org/" "mirror://hackage/"

-- "+a" -> "a"
-- "b"  -> "b"
sort_iuse :: [String] -> [String]
sort_iuse = L.sortBy (compare `F.on` dropWhile ( `elem` "+"))

type DString = String -> String

ss :: String -> DString
ss = showString

sc :: Char -> DString
sc = showChar

nl :: DString
nl = sc '\n'

verbatim :: DString -> [String] -> DString -> DString
verbatim pre s post =
    if null s
        then id
        else pre .
            (foldl (\acc v -> acc . ss "\t" . ss v . nl) id s) .
            post

-- takes string and substitutes tabs to spaces
-- ebuild's convention is 4 spaces for one tab,
-- BUT! nested USE flags get moved too much to
-- right. Thus 8 :]
tab_size :: Int
tab_size = 8

tabify_line :: String -> String
tabify_line l = replicate need_tabs '\t'  ++ nonsp
    where (sp, nonsp)       = break (/= ' ') l
          (full_tabs, t) = length sp `divMod` tab_size
          need_tabs = full_tabs + if t > 0 then 1 else 0

tabify :: String -> String
tabify = unlines . map tabify_line . lines

dep_str :: String -> [String] -> [Dependency] -> DString
dep_str var extra deps = ss var. sc '='. quote' (ss $ drop_leadings $ unlines extra ++ deps_s). nl
    where indent = 1 * tab_size
          deps_s = tabify (dep2str indent (DependAllOf deps))
          drop_leadings = dropWhile (== '\t')

quote :: String -> DString
quote str = sc '"'. ss (esc str). sc '"'
  where
  esc = concatMap esc'
  esc' '"' = "\""
  esc' c = [c]

quote' :: DString -> DString
quote' str = sc '"'. str. sc '"'

sepBy :: String -> [String] -> ShowS
sepBy _ []     = id
sepBy _ [x]    = ss x
sepBy s (x:xs) = ss x. ss s. sepBy s xs

getRestIfPrefix ::
    String ->    -- ^ the prefix
    String ->    -- ^ the string
    Maybe String
getRestIfPrefix (p:ps) (x:xs) = if p==x then getRestIfPrefix ps xs else Nothing
getRestIfPrefix [] rest = Just rest
getRestIfPrefix _ [] = Nothing

subStr ::
    String ->    -- ^ the search string
    String ->    -- ^ the string to be searched
    Maybe (String,String)  -- ^ Just (pre,post) if string is found
subStr sstr str = case getRestIfPrefix sstr str of
    Nothing -> if null str then Nothing else case subStr sstr (tail str) of
        Nothing -> Nothing
        Just (pre,post) -> Just (head str:pre,post)
    Just rest -> Just ([],rest)

replaceMultiVars ::
    [(String,String)] ->    -- ^ pairs of variable name and content
    String ->        -- ^ string to be searched
    String             -- ^ the result
replaceMultiVars [] str = str
replaceMultiVars whole@((pname,cont):rest) str = case subStr cont str of
    Nothing -> replaceMultiVars rest str
    Just (pre,post) -> (replaceMultiVars rest pre)++pname++(replaceMultiVars whole post)
