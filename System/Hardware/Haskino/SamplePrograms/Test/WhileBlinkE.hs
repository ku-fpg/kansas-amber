-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.Haskino.SamplePrograms.Test.WhileBlinkE
--                Based on System.Hardware.Arduino
-- Copyright   :  (c) University of Kansas
-- License     :  BSD3
-- Stability   :  experimental
--
-- The /hello world/ of the arduino world, blinking the led.  This version is
-- written with the expression based version of the commands and procedures
-- introduced in version 0.3 of Haskino
-------------------------------------------------------------------------------

module System.Hardware.Haskino.SamplePrograms.Test.WhileBlinkE where

import Prelude hiding ((<*))
import System.Hardware.Haskino
import Data.Boolean
import Data.Word

whileBlinkE :: IO ()
whileBlinkE = withArduino True "/dev/cu.usbmodem1421" $ do
              let led = 13
              let delay = 1000
              setPinModeE led OUTPUT
              whileE (lit (0::Word8)) (\x -> x <* 3)
                  (\x -> do
                      digitalWriteE led true
                      delayMillisE delay
                      digitalWriteE led false
                      delayMillisE delay
                      return $ x + 1)
              return ()
