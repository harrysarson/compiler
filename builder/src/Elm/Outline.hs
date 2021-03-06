{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
module Elm.Outline
  ( Outline(..)
  , AppOutline(..)
  , PkgOutline(..)
  , Exposed(..)
  , read
  , write
  , encode
  , decoder
  , defaultSummary
  , flattenExposed
  )
  where


import Prelude hiding (read)
import Control.Monad (filterM, liftM)
import Data.Binary (Binary, get, put, getWord8, putWord8)
import Data.Foldable (traverse_)
import qualified Data.Map as Map
import qualified Data.NonEmptyList as NE
import qualified Data.Utf8 as Utf8
import qualified System.Directory as Dir
import System.FilePath ((</>))

import qualified Elm.Constraint as Con
import qualified Elm.Licenses as Licenses
import qualified Elm.ModuleName as ModuleName
import qualified Elm.Package as Pkg
import qualified Elm.Version as V
import qualified File
import qualified Json.Decode as D
import qualified Json.Encode as E
import qualified Reporting.Exit as Exit



-- OUTLINE


data Outline
  = App AppOutline
  | Pkg PkgOutline


data AppOutline =
  AppOutline
    { _app_elm_version :: V.Version
    , _app_source_dirs :: NE.List FilePath
    , _app_deps_direct :: Map.Map Pkg.Name V.Version
    , _app_deps_indirect :: Map.Map Pkg.Name V.Version
    , _app_test_direct :: Map.Map Pkg.Name V.Version
    , _app_test_indirect :: Map.Map Pkg.Name V.Version
    }


data PkgOutline =
  PkgOutline
    { _pkg_name :: Pkg.Name
    , _pkg_summary :: Utf8.String
    , _pkg_license :: Licenses.License
    , _pkg_version :: V.Version
    , _pkg_exposed :: Exposed
    , _pkg_deps :: Map.Map Pkg.Name Con.Constraint
    , _pkg_test_deps :: Map.Map Pkg.Name Con.Constraint
    , _pkg_elm_version :: Con.Constraint
    }


data Exposed
  = ExposedList [ModuleName.Raw]
  | ExposedDict [(Utf8.String, [ModuleName.Raw])]



-- DEFAULTS


defaultSummary :: Utf8.String
defaultSummary =
  "helpful summary of your project, less than 80 characters"



-- HELPERS


flattenExposed :: Exposed -> [ModuleName.Raw]
flattenExposed exposed =
  case exposed of
    ExposedList names ->
      names

    ExposedDict sections ->
      concatMap snd sections



-- WRITE


write :: FilePath -> Outline -> IO ()
write root outline =
  E.write (root </> "elm.json") (encode outline)



-- JSON ENCODE


encode :: Outline -> E.Value
encode outline =
  case outline of
    App (AppOutline elm srcDirs depsDirect depsTrans testDirect testTrans) ->
      E.object
        [ "type" ==> E.string "application"
        , "source-directories" ==> E.list (E.string . Utf8.fromChars) (NE.toList srcDirs)
        , "elm-version" ==> V.encode elm
        , "dependencies" ==>
            E.object
              [ "direct" ==> encodeDeps V.encode depsDirect
              , "indirect" ==> encodeDeps V.encode depsTrans
              ]
        , "test-dependencies" ==>
            E.object
              [ "direct" ==> encodeDeps V.encode testDirect
              , "indirect" ==> encodeDeps V.encode testTrans
              ]
        ]

    Pkg (PkgOutline name summary license version exposed deps tests elm) ->
      E.object
        [ "type" ==> E.string "package"
        , "name" ==> Pkg.encode name
        , "summary" ==> E.string summary
        , "license" ==> Licenses.encode license
        , "version" ==> V.encode version
        , "exposed-modules" ==> encodeExposed exposed
        , "elm-version" ==> Con.encode elm
        , "dependencies" ==> encodeDeps Con.encode deps
        , "test-dependencies" ==> encodeDeps Con.encode tests
        ]


(==>) :: a -> b -> (a, b)
(==>) a b =
  (a, b)


encodeExposed :: Exposed -> E.Value
encodeExposed exposed =
  case exposed of
    ExposedList modules ->
      E.list encodeModule modules

    ExposedDict chunks ->
      E.object (map (fmap (E.list encodeModule)) chunks)


encodeModule :: ModuleName.Raw -> E.Value
encodeModule name =
  E.name name


encodeDeps :: (a -> E.Value) -> Map.Map Pkg.Name a -> E.Value
encodeDeps encodeValue deps =
  E.dict Pkg.toString encodeValue deps



-- PARSE AND VERIFY


read :: FilePath -> IO (Either Exit.Outline Outline)
read root =
  do  bytes <- File.readUtf8 (root </> "elm.json")
      case D.fromByteString decoder bytes of
        Left err ->
          return $ Left (Exit.OutlineHasBadStructure err)

        Right outline ->
          case outline of
            Pkg _ ->
              return $ Right outline

            App (AppOutline _ srcDirs _ _ _ _) ->
              do  badDirs <- filterM (isBadSrcDir root) (NE.toList srcDirs)
                  case badDirs of
                    []   -> return $ Right outline
                    d:ds -> return $ Left (Exit.OutlineHasBadSrcDirs d ds)


isBadSrcDir :: FilePath -> FilePath -> IO Bool
isBadSrcDir root dir =
  not <$> Dir.doesDirectoryExist (root </> dir)



-- JSON DECODE


type Decoder a =
  D.Decoder Exit.OutlineProblem a


decoder :: Decoder Outline
decoder =
  do  tipe <- D.field "type" D.string
      case tipe of
        "application" ->
          App <$> appDecoder

        "package" ->
          Pkg <$> pkgDecoder

        other ->
          D.failure (Exit.OP_BadType other)


appDecoder :: Decoder AppOutline
appDecoder =
  AppOutline
    <$> D.field "elm-version" versionDecoder
    <*> D.field "source-directories" dirsDecoder
    <*> D.field "dependencies" (D.field "direct" (depsDecoder versionDecoder))
    <*> D.field "dependencies" (D.field "indirect" (depsDecoder versionDecoder))
    <*> D.field "test-dependencies" (D.field "direct" (depsDecoder versionDecoder))
    <*> D.field "test-dependencies" (D.field "indirect" (depsDecoder versionDecoder))


pkgDecoder :: Decoder PkgOutline
pkgDecoder =
  PkgOutline
    <$> D.field "name" (D.mapError Exit.OP_BadPkgName Pkg.decoder)
    <*> D.field "summary" summaryDecoder
    <*> D.field "license" (Licenses.decoder Exit.OP_BadLicense)
    <*> D.field "version" versionDecoder
    <*> D.field "exposed-modules" exposedDecoder
    <*> D.field "dependencies" (depsDecoder constraintDecoder)
    <*> D.field "test-dependencies" (depsDecoder constraintDecoder)
    <*> D.field "elm-version" constraintDecoder



-- JSON DECODE HELPERS


summaryDecoder :: Decoder Utf8.String
summaryDecoder =
  do  summary <- D.string
      if Utf8.size summary < 80
        then return summary
        else D.failure Exit.OP_BadSummaryTooLong


versionDecoder :: Decoder V.Version
versionDecoder =
  D.mapError Exit.OP_BadVersion V.decoder


constraintDecoder :: Decoder Con.Constraint
constraintDecoder =
  D.mapError Exit.OP_BadConstraint Con.decoder


depsDecoder :: Decoder a -> Decoder (Map.Map Pkg.Name a)
depsDecoder valueDecoder =
  Map.fromList <$> (
    traverse validateKey =<< D.pairs valueDecoder
  )


validateKey :: (Utf8.String, a) -> Decoder (Pkg.Name, a)
validateKey (key, value) =
  case Pkg.fromString key of
    Right name ->
      return (name, value)

    Left _ ->
      D.failure (Exit.OP_BadDependencyName key)


dirsDecoder :: Decoder (NE.List FilePath)
dirsDecoder =
  do  dirs <- D.list D.string
      case map Utf8.toChars dirs of
        d:ds -> return (NE.List d ds)
        []   -> D.failure Exit.OP_NoSrcDirs



-- EXPOSED MODULES DECODER


exposedDecoder :: Decoder Exposed
exposedDecoder =
  D.oneOf
    [ ExposedList <$> D.list moduleDecoder
    , do  pairs <- D.pairs (D.list moduleDecoder)
          traverse_ (checkHeader . fst) pairs
          return (ExposedDict pairs)
    ]


moduleDecoder :: Decoder ModuleName.Raw
moduleDecoder =
  D.mapError Exit.OP_BadModuleName ModuleName.decoder


checkHeader :: Utf8.String -> Decoder ()
checkHeader header =
  if Utf8.size header < 20
    then return ()
    else D.failure (Exit.OP_BadModuleHeaderTooLong header)



-- BINARY


instance Binary Outline where
  put outline =
    case outline of
      App a -> putWord8 0 >> put a
      Pkg a -> putWord8 1 >> put a

  get =
    do  n <- getWord8
        case n of
          0 -> liftM App get
          1 -> liftM Pkg get
          _ -> error "binary encoding of Outline was corrupted"


instance Binary AppOutline where
  put (AppOutline a b c d e f) =
    put a >> put b >> put c >> put d >> put e >> put f

  get =
    do  a <- get
        b <- get
        c <- get
        d <- get
        e <- get
        f <- get
        return (AppOutline a b c d e f)


instance Binary PkgOutline where
  put (PkgOutline a b c d e f g h) =
    put a >> put b >> put c >> put d >> put e >> put f >> put g >> put h

  get =
    do  a <- get
        b <- get
        c <- get
        d <- get
        e <- get
        f <- get
        g <- get
        h <- get
        return (PkgOutline a b c d e f g h)


instance Binary Exposed where
  put exposed =
    case exposed of
      ExposedList a -> putWord8 0 >> put a
      ExposedDict a -> putWord8 1 >> put a

  get =
    do  n <- getWord8
        case n of
          0 -> liftM ExposedList get
          1 -> liftM ExposedDict get
          _ -> error "binary encoding of ProjectDeps was corrupted"
