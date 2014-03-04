{-# OPTIONS_GHC -Wall #-}

module Main ( main
            ) where

import Linear
import SpatialMath ( Euler(..), rotateXyzAboutY, rotVecByEulerB2A, rotateXyzAboutX )
import Graphics.X11 ( initThreads )
import Vis
import Graphics.UI.GLUT hiding ( Plane, Sphere, Points, Cube, motionCallback, samples )
import qualified Data.Set as Set
import Control.Monad ( when )

import Numeric.LinearAlgebra

import InternalMath
import Feature
import Simulate

-- for debugging
import System.IO.Unsafe (unsafePerformIO)
debug :: Show a => String -> a -> a
debug s a = unsafePerformIO (print $ s ++ ": " ++ show a) `seq` a
infixr 1 `debug`

ts :: Double
ts = 0.01

faceHeight :: Double
faceHeight = 1.5

data ObserverState = Running (V3 Double) (V3 Double) (Euler Double)
data InputState = Input { keySet :: Set.Set Key, lastMousePos :: Maybe (GLint, GLint) }
data SLAMState = SLAM { camera :: Camera, features :: [Feature] }

data GameState = GameState { observer :: ObserverState
                           , input :: InputState
                           , slam :: SLAMState 
                           }

toVertex :: (Real a, Fractional b) => V3 a -> Vertex3 b
toVertex xyz = (\(V3 x y z) -> Vertex3 x y z) $ fmap realToFrac xyz

setCamera :: ObserverState -> IO ()
setCamera (Running (V3 x y z) _ euler) = lookAt (toVertex xyz0) (toVertex target) (Vector3 0 (-1) 0)
	where
		xyz0 = V3 x (y-faceHeight) z
		target = xyz0 + rotateXyzAboutY (rotateXyzAboutX (rotVecByEulerB2A euler (V3 1 0 0)) (-pi/2)) (-pi/2)

simfun :: Float -> GameState -> IO GameState
simfun _ (GameState (Running pos _ euler0@(Euler yaw _ _)) (Input keys lmp) ss) = do
	Size x y <- get windowSize
	let 
		x' = (fromIntegral x) `div` 2
		y' = (fromIntegral y) `div` 2

	when (Just (x',y') /= lmp) (pointerPosition $= (Position x' y'))
	return $ GameState (Running (pos + (ts *^ v)) v euler0) 
					   (Input keys (Just (x',y'))) 
					   ss { camera = newcam (camera ss), features = features ss }
	where
		keyPressed k = Set.member (Char k) keys
		newcam (Camera cp cr) = Camera (cp + cr <> (3|> [right-left,0,up-down])) (cr <> rot) where
				rot = rotateYmat (rturn-lturn)
				up    = if keyPressed 'u' then ts else 0
				down  = if keyPressed 'e' then ts else 0
				left  = if keyPressed 'n' then ts else 0
				right = if keyPressed 'i' then ts else 0
				lturn = if keyPressed 'l' then ts else 0
				rturn = if keyPressed 'y' then ts else 0
		v = rotateXyzAboutY (V3 (d-a) 0 (w-s)) yaw where
				w = if keyPressed 'w' then 3 else 0
				a = if keyPressed 'a' then 3 else 0
				s = if keyPressed 'r' then 3 else 0
				d = if keyPressed 's' then 3 else 0

keyMouseCallback :: GameState -> Key -> KeyState -> Modifiers -> Position -> GameState
keyMouseCallback state0 key keystate _ _
	| keystate == Down = state0 {input = (input state0) {keySet = Set.insert key (keySet $ input state0)}}
	| keystate == Up   = state0 {input = (input state0) {keySet = Set.delete key (keySet $ input state0)}}
	| otherwise        = state0

motionCallback :: Bool -> GameState -> Position -> GameState
motionCallback _ state0@(GameState (Running pos v (Euler yaw0 pitch0 _)) (Input keys lmp) _) (Position x y) =
	state0 { observer = newObserver, input = Input keys (Just (x,y)) }
	where
		(x0,y0) = case lmp of Nothing -> (x,y)
		                      Just (x0',y0') -> (x0',y0')
		newObserver = Running pos v (Euler yaw pitch 0)
		dx = 0.002*realToFrac (x - x0)
		dy = 0.002*realToFrac (y - y0)
		yaw = yaw0 + dx
		pitch = bound (-pi/2.1) (pi/2.1) (pitch0 - dy)
		bound min' max' val
			| val < min' = min'
			| val > max' = max'
			| otherwise  = val
    

drawfun :: GameState -> VisObject Double
drawfun (GameState (Running _ _ _) _ (SLAM cam fs)) =
	VisObjects $ [drawBackground, drawCamera cam] ++ map drawLandmark landmarks
   
drawBackground :: VisObject Double
drawBackground = VisObjects [Axes (1, 25), Plane (V3 0 1 0) (makeColor 1 0 0 1)]

drawFeature :: Feature -> VisObject Double
drawFeature f = Points (map vec2v3 (take 300 $ samples f 10)) (Just 3) (makeColor 0 0 0 1) where
	vec2v3 v = V3 (v@>0) (v@>1) (v@>2)
	
drawLandmark :: V3 Double -> VisObject Double
drawLandmark l = Trans l $ Sphere 0.15 Wireframe (makeColor 0.2 0.3 0.8 1)

drawCamera :: Camera -> VisObject Double
drawCamera (Camera cp cr) = Trans (v2V cp) $ VisObjects 
		[ Cube 0.2 Wireframe color'
		, Arrow (0.5, 20) (v2V $ cr <> (3|> [0,0,1])) color'
		] where
			v2V v = V3 (v@>0) (v@>1) (v@>2)
			color' = makeColor 0 0.7 0 1
			
	
main :: IO ()
main = do
	let 
		state0 = GameState 
				(Running (V3 0 0 (-5)) 0 (Euler 0 0 0)) 
				(Input (Set.empty) Nothing)
				(SLAM (Camera (3|> repeat 0) (ident 3)) [])
		setCam (GameState x _ _) = setCamera x
		drawfun' x = return (drawfun x, Just None)
	_ <- initThreads
	playIO Nothing "play test" ts state0 drawfun' simfun setCam
		(Just keyMouseCallback) (Just (motionCallback True)) (Just (motionCallback False))
