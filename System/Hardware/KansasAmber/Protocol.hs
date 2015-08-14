-------------------------------------------------------------------------------
-- |
-- Module      :  System.Hardware.KansasAmber.Comm
--                Based on System.Hardware.Arduino.comm
-- Copyright   :  (c) University of Kansas
--                System.Hardware.Arduino (c) Levent Erkok
-- License     :  BSD3
-- Stability   :  experimental
--
-- Internal representation of the firmata protocol.
-------------------------------------------------------------------------------
{-# LANGUAGE GADTs      #-}

module System.Hardware.KansasAmber.Protocol(packageCommand, packageProcedure, unpackageResponse, parseQueryResult) where

import Data.Bits            (xor)
import Data.Word (Word8)

import qualified Data.ByteString as B

import System.Hardware.KansasAmber.Data
import System.Hardware.KansasAmber.Utils

-- | Maximum size of a firmata message
maxFirmwareSize :: Int
maxFirmwareSize = 128

hdlcFrameCommand :: [Word8] -> [Word8]
hdlcFrameCommand cs = (concatMap escape cs) ++ [0x7E]
  where
    escape :: Word8 -> [Word8]
    escape c = if c == 0x7E || c == 0x7D
               then [0x7D, xor c 0x20]
               else [c]

buildCommand :: FirmwareCmd -> [Word8] -> B.ByteString
buildCommand cmd bs = B.pack $ hdlcFrameCommand $ firmwareCmdVal cmd : bs

-- | Package a request as a sequence of bytes to be sent to the board
-- using the Firmata protocol.
packageCommand :: ArduinoConnection -> Command -> IO B.ByteString
packageCommand c SystemReset = 
    return $ buildCommand BC_CMD_SYSTEM_RESET []
packageCommand c (SetPinMode p m) = do
    return $ buildCommand BC_CMD_SET_PIN_MODE [p, fromIntegral $ fromEnum m]
packageCommand c (DigitalWrite p b)  = do
    return $ buildCommand DIG_CMD_WRITE_PIN [p, if b then 1 else 0]
packageCommand c (AnalogWrite p w) = do
    return $ buildCommand ALG_CMD_WRITE_PIN (p : (word16ToBytes w))
packageCommand c (I2CWrite sa w8s) = 
    return $ buildCommand I2C_CMD_WRITE (sa : w8s)
packageCommand c (DeleteTask tid) = 
    return $ buildCommand SCHED_CMD_DELETE_TASK [tid]
packageCommand c (DelayMillis ms) = 
    return $ buildCommand BC_CMD_DELAY_MILLIS (word32ToArduinoBytes ms)
packageCommand c (DelayMicros ms) = 
    return $ buildCommand BC_CMD_DELAY_MICROS (word32ToArduinoBytes ms)
packageCommand c (ScheduleTask tid tt)    = 
    return $ buildCommand SCHED_CMD_DELETE_TASK (tid : word32ToBytes tt)
{-
packageCommand c (CreateTask tid m)       = do
    td <- packageTaskData c m
    let taskSize = fromIntegral (B.length td)
    return $ buildCommand SCHED_CMD_CREATE_TASK (tid : (word16ToBytes taskSize))
                                    `B.append` (genAddToTaskCmds td)
  where
    maxCmdSize = maxFirmwareSize - 3
    genAddToTaskCmds tds | fromIntegral (B.length tds) > maxCmdSize = 
        addToTask (B.take maxCmdSize tds) 
            `B.append` (genAddToTaskCmds (B.drop maxCmdSize tds))
    genAddToTaskCmds tds = addToTask tds
    addToTask tds' = (buildCommand SCHED_CMD_ADD_TO_TASK [tid]) 
                           `B.append` tds'
-}
{- 
packageCommand c (StepperConfig dev TwoWire d sr p1 p2 _ _) = do
    ipin1 <-  getInternalPin c p1 
    ipin2 <-  getInternalPin c p2
    let pn1 = fromIntegral $ pinNo ipin1
        pn2 = fromIntegral $ pinNo ipin2
    return $ sysEx STEPPER_DATA ([stepperCmdVal CONFIG_STEPPER,dev,((stepDelayVal d) .|. 0x02)] ++ (word16ToArduinoBytes sr) ++ [pn1,pn2])
packageCommand c (StepperConfig dev FourWire d sr p1 p2 (Just p3) (Just p4)) = do 
    ipin1 <-  getInternalPin c p1 
    ipin2 <-  getInternalPin c p2
    ipin3 <-  getInternalPin c p3 
    ipin4 <-  getInternalPin c p4
    let pn1 = fromIntegral $ pinNo ipin1
        pn2 = fromIntegral $ pinNo ipin2
        pn3 = fromIntegral $ pinNo ipin3
        pn4 = fromIntegral $ pinNo ipin4
    return $ sysEx STEPPER_DATA ([stepperCmdVal CONFIG_STEPPER,dev,((stepDelayVal d) .|. 0x04)] ++ (word16ToArduinoBytes sr) ++ [pn1,pn2,pn3,pn4])
packageCommand c (StepperConfig _ FourWire _ _ _ _ _ _) = 
    runDie c "KansasAmber: FourWire steppers require specification of 4 pins for config"  []
packageCommand c (StepperConfig dev StepDir d sr dp sp _ _) = do
    dipin <-  getInternalPin c dp 
    sipin <-  getInternalPin c sp
    let pnd = fromIntegral $ pinNo dipin
        pns = fromIntegral $ pinNo sipin
    return $ sysEx STEPPER_DATA ([stepperCmdVal CONFIG_STEPPER,dev,((stepDelayVal d) .|. 0x01)] ++ (word16ToArduinoBytes sr) ++ [pnd,pns])
packageCommand c (StepperStep dev sd ns sp (Just ac)) =
    return $ sysEx STEPPER_DATA ([stepperCmdVal STEP_STEPPER,dev,(stepDirVal sd)] ++ (word32To3ArduinoBytes ns) ++ (word16ToArduinoBytes sp) ++ (intTo4ArduinoBytes ac))
packageCommand c (StepperStep dev sd ns sp Nothing) =
    return $ sysEx STEPPER_DATA ([stepperCmdVal STEP_STEPPER,dev,(stepDirVal sd)] ++ (word32To3ArduinoBytes ns) ++ (word16ToArduinoBytes sp))
packageCommand c (ServoConfig p min max)  = do
    ipin <- getInternalPin c p
    return $ sysEx SERVO_CONFIG ([fromIntegral $ pinNo ipin] ++ (word16ToArduinoBytes min) ++ (word16ToArduinoBytes max))
-}

packageTaskData :: ArduinoConnection -> Arduino a -> IO B.ByteString
packageTaskData conn commands =
      packageTaskData' conn commands B.empty
  where
      packBind :: ArduinoConnection -> Arduino a -> (a -> Arduino b) -> IO B.ByteString -> IO B.ByteString
      packBind c (Return a)      k cmds = do
          cs <- cmds
          packageTaskData' c (k a) cs
      packBind c (Bind m k1)    k2 cmds = packBind c m (\ r -> Bind (k1 r) k2) cmds
      packBind c (Command cmd) k cmds = do
          proc <- packageCommand c cmd
          cs <- cmds
          packageTaskData' c (k ()) (B.append cs proc)
      packBind c (Local local) k cmds = packLocal c local k cmds
      packBind c (Procedure procedure) k cmds = packProcedure c procedure k cmds

      -- For sending as part of a Scheduler task, locals make no sense.  
      -- Instead of signalling an error, at this point they are just ignored.
      packLocal :: ArduinoConnection -> Local a -> (a -> Arduino b) -> IO B.ByteString -> IO B.ByteString
      packLocal c (Debug _) k cmds = do
          cs <- cmds 
          packageTaskData' c (k ()) cs
      packLocal c (Die _ _) k cmds = do
          cs <- cmds 
          packageTaskData' c (k ()) cs

      packProcedure :: ArduinoConnection -> Procedure a -> (a -> Arduino b) -> IO B.ByteString -> IO B.ByteString
      packProcedure c QueryFirmware k cmds = do 
          cs <- cmds           
          packageTaskData' c (k (0,0)) cs
      packProcedure c QueryProcessor k cmds = do 
          cs <- cmds           
          packageTaskData' c (k ATMEGA8) cs
      packProcedure c (DigitalRead _) k cmds = do 
          cs <- cmds           
          packageTaskData' c (k False) cs
      packProcedure c (AnalogRead _) k cmds = do 
          cs <- cmds           
          packageTaskData' c (k 0) cs
--      packProcedure c (Pulse _ _ _ _) k cmds = do
--          cs <- cmds 
--          packageTaskData' c (k 0) cs
      packProcedure c QueryAllTasks k cmds = do
          cs <- cmds
          packageTaskData' c (k ([])) cs
      packProcedure c (QueryTask _) k cmds = do
          cs <- cmds
          packageTaskData' c (k Nothing) cs

      packageTaskData' :: ArduinoConnection -> Arduino a -> B.ByteString -> IO B.ByteString
      packageTaskData' c (Bind m k) cmds = packBind c m k (return cmds)
      packageTaskData' c (Return a) cmds = return cmds
      packageTaskData' c cmd        cmds = packBind c cmd Return (return cmds)

packageProcedure :: Procedure a -> B.ByteString
packageProcedure QueryFirmware       = 
    buildCommand BS_CMD_REQUEST_VERSION []
packageProcedure QueryProcessor      = 
    buildCommand BS_CMD_REQUEST_TYPE []
packageProcedure (DigitalRead p)     = 
    buildCommand DIG_CMD_READ_PIN [p]
packageProcedure (AnalogRead p)      = 
    buildCommand ALG_CMD_READ_PIN [p]
packageProcedure (I2CRead sa Nothing cnt)    = 
    buildCommand I2C_CMD_READ [sa,cnt]
packageProcedure (I2CRead sa (Just sr) cnt) = 
    buildCommand I2C_CMD_READ_REG ((sa : (word16ToBytes sr)) ++ [cnt])
packageProcedure QueryAllTasks       = 
    buildCommand SCHED_CMD_QUERY_ALL []
packageProcedure (QueryTask tid)     = 
    buildCommand SCHED_CMD_QUERY [tid]
-- packageProcedure (Pulse p b dur to)       = sysEx    PULSE                   ([fromIntegral (pinNo p), if b then 1 else 0] ++ concatMap toArduinoBytes (word32ToBytes dur ++ word32ToBytes to))

-- | Unpackage a SysEx response
unpackageResponse :: [Word8] -> Response
unpackageResponse [] = Unimplemented (Just "<EMPTY-REPLY>") []
unpackageResponse (cmdWord:args)
  | Right cmd <- getFirmwareReply cmdWord
  = case (cmd, args) of
      (BS_RESP_VERSION, [majV, minV]) -> Firmware majV minV
      (BS_RESP_TYPE, [p])               -> ProcessorType p
--      (PULSE, xs) | length xs == 10          -> let [p, a, b, c, d] = fromArduinoBytes xs in PulseResponse (InternalPin p) (bytesToWord32 (a, b, c, d))
      (BS_RESP_STRING, rest)          -> StringMessage (getString rest)
      (I2C_RESP_READ, xs)             -> I2CReply xs
      (SCHED_RESP_QUERY_ALL, ts)      -> QueryAllTasksReply ts
      (SCHED_RESP_QUERY, ts) | length ts == 0 -> 
          QueryTaskReply Nothing
      -- TBD Fix reply decode
      (SCHED_RESP_QUERY, ts) | length ts >= 9 -> 
          let tid:tt0:tt1:tt2:tt3:tl0:tl1:tp0:tp1:rest = ts
          in QueryTaskReply (Just (tid, bytesToWord32 (tt3,tt2,tt1,tt0),  
                              bytesToWord16 (tl1,tl0), bytesToWord16 (tp1,tp0)))
      _                               -> Unimplemented (Just (show cmd)) args
  | True
  = Unimplemented Nothing (cmdWord : args)

-- This is how we match responses with queries
parseQueryResult :: Procedure a -> Response -> Maybe a
parseQueryResult QueryFirmware (Firmware wa wb) = Just (wa,wb)
parseQueryResult QueryProcessor (ProcessorType pt) = Just $ getProcessor pt
parseQueryResult (DigitalRead p) (DigitalReply d) = Just (if d == 0 then False else True)
parseQueryResult (AnalogRead p) (AnalogReply a) = Just a
-- parseQueryResult (Pulse p b dur to) (PulseResponse p2 w) = Just w
parseQueryResult (I2CRead saq srq cnt) (I2CReply ds) = Just ds
parseQueryResult QueryAllTasks (QueryAllTasksReply ts) = Just ts
parseQueryResult (QueryTask tid) (QueryTaskReply tr) = Just tr
parseQueryResult q r = Nothing