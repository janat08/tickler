{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}

module Tickler.Server.Handler.GetLoopersStatusSpec
    ( spec
    ) where

import TestImport

import Tickler.Client

import Tickler.Client.Gen ()
import Tickler.Data.Gen ()
import Tickler.Server.TestUtils

spec :: Spec
spec =
    withTicklerServer $
    describe "GetLoopersStatus" $
    it "gets a valid loopers status" $ \cenv -> do
        r <- runClientOrError cenv clientGetLoopersStatus
        shouldBeValid r
