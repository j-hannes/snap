{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Snap.Loader.Hint where

------------------------------------------------------------------------------
import qualified Data.ByteString.Char8 as S

import           Data.List (groupBy, intercalate, isPrefixOf, nub)

import           Control.Concurrent (forkIO, myThreadId)
import           Control.Concurrent.MVar
import           Control.Exception
import           Control.Monad (when)
import           Control.Monad.Trans (liftIO)

import           Data.Maybe (catMaybes)
import           Data.Time.Clock

import           Language.Haskell.Interpreter hiding (lift, liftIO)
import           Language.Haskell.Interpreter.Unsafe (unsafeSetGhcOption)

import           Language.Haskell.TH.Syntax

import           Prelude hiding (catch)

import           System.Environment (getArgs)

------------------------------------------------------------------------------
import           Snap.Error
import           Snap.Types
import qualified Snap.Loader.Static as Static

------------------------------------------------------------------------------
-- | XXX
-- Assumes being spliced into the same source tree as the action to
-- dynamically load is located in
loadSnapTH :: Name -> Name -> Name -> Q Exp
loadSnapTH initialize cleanup action = do
    args <- runIO getArgs

    let initMod = nameModule initialize
        initBase = nameBase initialize
        cleanMod = nameModule cleanup
        cleanBase = nameBase cleanup
        actMod = nameModule action
        actBase = nameBase action

        modules = catMaybes [initMod, cleanMod, actMod]
        opts = getHintOpts args

    hintSnapE <- [| \o m i c a ->
                      fmap ((,) $ return ()) $ hintSnap o m i c a |]

    [ optsE, modulesE ]     <- mapM lift [ opts, modules ]
    [ initE, cleanE, actE ] <- mapM lift [ initBase, cleanBase, actBase ]

    staticE <- Static.loadSnapTH initialize cleanup action

    -- Wrap the hintSnap call in a let block.  This let block
    -- vacuously pattern-matches the static expression, providing an
    -- extra check that the types were correct at compile-time, at
    -- least.  This check isn't infallible, because the type isn't
    -- fully specified, but it's an extra level of help with
    -- negligible compile-time cost.
    let hintApp = foldl AppE hintSnapE [optsE, modulesE, initE, cleanE, actE]
        nameUnused = mkName "_"
        body = NormalB staticE
        clause = Clause [] body []
        staticDec = FunD nameUnused [clause]

    return $ LetE [staticDec] hintApp


------------------------------------------------------------------------------
-- | XXX
getHintOpts :: [String] -> [String]
getHintOpts args = "-hide-package=mtl" : "-hide-package=MonadCatchIO-mtl" :
                   filter (not . (`elem` bad)) opts
  where
    bad = ["-threaded"]
    hideAll = filter (== "-hide-all-packages") args

    srcOpts = filter (\x -> "-i" `isPrefixOf` x
                            && not ("-idist" `isPrefixOf` x)) args

    toCopy = init $ dropWhile (not . ("-package" `isPrefixOf`)) args
    copy = map (intercalate " ") . groupBy (\_ s -> not $ "-" `isPrefixOf` s)

    opts = hideAll ++ srcOpts ++ copy toCopy


------------------------------------------------------------------------------
-- | XXX
hintSnap :: [String] -> [String] -> String -> String -> String -> IO (Snap ())
hintSnap opts mNames initBase cleanBase actBase = do
    let action = intercalate " " ["bracketSnap", initBase, cleanBase, actBase]
        interpreter = do
            mapM_ unsafeSetGhcOption opts
            loadModules . nub $ mNames
            let allMods = "Prelude" : "Snap.Types" : mNames
            setImports . nub $ allMods
            interpret action (as :: Snap ())

    loadAction <- protectedActionEvaluator 3 $ runInterpreter interpreter

    return $ do
        eSnap <- liftIO loadAction
        case eSnap of
            Left err -> internalError $ format err
            Right handler -> catch500 handler


------------------------------------------------------------------------------
-- | XXX
format :: InterpreterError -> S.ByteString
format (UnknownError e)   =
    S.append "Unknown interpreter error:\r\n\r\n" $ S.pack e

format (NotAllowed e)     =
    S.append "Interpreter action not allowed:\r\n\r\n" $ S.pack e

format (GhcException e)   =
    S.append "GHC error:\r\n\r\n" $ S.pack e

format (WontCompile errs) =
    let formatted = S.intercalate "\r\n" . map S.pack . nub . map errMsg $ errs
    in S.append "Compile errors:\r\n\r\n" formatted


------------------------------------------------------------------------------
-- | Create a wrapper for an action that protects the action from
-- concurrent or rapid evaluation.
--
-- There will be at least the passed-in 'NominalDiffTime' delay
-- between the finish of one execution of the action the start of the
-- next.  Concurrent calls to the wrapper, and calls within the delay
-- period, end up with the same calculated value returned.
--
-- If an exception is raised during the processing of the action, it
-- will be thrown to all waiting threads, and for all requests made
-- before the delay time has expired after the exception was raised.
protectedActionEvaluator :: NominalDiffTime -> IO a -> IO (IO a)
protectedActionEvaluator minReEval action = do
    -- The list of requesters waiting for a result.  Contains the
    -- ThreadId in case of exceptions, and an empty MVar awaiting a
    -- successful result.
    --
    -- type: MVar [(ThreadId, MVar a)]
    readerContainer <- newMVar []

    -- Contains the previous result, and the time it was stored, if a
    -- previous result has been computed.  The result stored is either
    -- the actual result, or the exception thrown by the calculation.
    --
    -- type: MVar (Maybe (Either SomeException a, UTCTime))
    resultContainer <- newMVar Nothing

    -- The model used for the above MVars in the returned action is
    -- "keep them full, unless updating them."  In every case, when
    -- one of those MVars is emptied, the next action is to fill that
    -- same MVar.  This makes deadlocking on MVar wait impossible.
    return $ do
        existingResult <- readMVar resultContainer
        now <- getCurrentTime

        case existingResult of
            Just (res, ts) | diffUTCTime now ts < minReEval ->
                -- There's an existing result, and it's still valid
                case res of
                    Right val -> return val
                    Left  e   -> throwIO e
            _ -> do
                -- Need to calculate a new result
                tid <- myThreadId
                reader <- newEmptyMVar

                readers <- takeMVar readerContainer

                -- Some strictness is employed to ensure the MVar
                -- isn't holding on to a chain of unevaluated thunks.
                let pair = (tid, reader)
                    newReaders = pair `seq` (pair : readers)
                putMVar readerContainer $! newReaders

                -- If this is the first reader, kick off evaluation of
                -- the action in a new thread. This is slightly
                -- careful to block asynchronous exceptions to that
                -- thread except when actually running the action.
                when (null readers) $ do
                    let runAndFill = block $ do
                            a <- unblock action
                            clearAndNotify (Right a) (flip putMVar a . snd)

                        killWaiting :: SomeException -> IO ()
                        killWaiting e = block $ do
                            clearAndNotify (Left e) (flip throwTo e . fst)
                            throwIO e

                        clearAndNotify r f = do
                            t <- getCurrentTime
                            _ <- swapMVar resultContainer $ Just (r, t)
                            allReaders <- swapMVar readerContainer []
                            mapM_ f allReaders

                    _ <- forkIO $ runAndFill `catch` killWaiting
                    return ()

                -- Wait for the evaluation of the action to complete,
                -- and return its result.
                takeMVar reader
