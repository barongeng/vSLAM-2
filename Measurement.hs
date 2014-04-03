
module Measurement where

import Numeric.LinearAlgebra
import Numeric.LinearAlgebra.Util ((!))

import InternalMath
import Landmark
import Camera

-- | TODO: tie this with the covariance, defined for observations in PHDSLAM.hs
initialCov :: Matrix Double
initialCov = diag(6|> [0,0,0,0.01,0.01,0.5])

-- | TODO: check the correctness of this value (10 or 1/10 or other?)
initialRho :: Double
initialRho = 0.2


-- | Initialize a landmark from a single measurement. Tuple contains mean theta and phi angles,
-- relative to the robot (the bearing of an observed feature).
-- TODO: implement the angle computations
initialize :: ExactCamera -> Feature -> Landmark
initialize (ExactCamera cpos crot) (Feature landmark_id angles) = Landmark
		landmark_id  (join [cpos, 3 |> [theta, phi, initialRho]])  initialCov where
	h = euler2vec angles
	(theta, phi) = vec2euler . head.toColumns $ crot <> asColumn h

--------------------------------------------------------------------------------

-- | 6D Landmark mean to a directional (un-normalized) vector in camera-space.
-- The first parameter is the camera position, the second is the landmark mean.
-- The result is (obviously) independent of camera rotation.
measure_g :: Vector Double -> Vector Double -> Vector Double
measure_g camPos f = scale rho (fpos - camPos) + euler2vec (theta, phi) where
	[fpos, tmp] = takesV [3,3] f
	[theta, phi, rho] = toList tmp

-- | 6D Landmark mean to a directional (un-normalized) vector in world-space.
measure_h :: ExactCamera -> Vector Double -> Vector Double
measure_h (ExactCamera cpos crot) f = head.toColumns $ trans crot <> asColumn (measure_g cpos f)

-- | The projection of the 6D Landmark mean into theta-phi parametrisation.
measure :: ExactCamera -> Vector Double -> (Double, Double)
measure c f = vec2euler $ measure_h c f


-- | Measurement equation jacobian with respect to the landmark
jacobian_l :: ExactCamera -> Vector Double -> Matrix Double
jacobian_l (cam@(ExactCamera cpos crot)) f = fromRows [e1', e2'] where
	[x, y, z, theta, phi, rho] = toList f
	[x_c, y_c, z_c] = toList cpos
	[h_x, h_y, h_z] = toList $ measure_h cam f
	[h_x', h_y', h_z'] = toRows h'
	h' = trans crot <> ((3><6) 
		[ rho,   0,   0,  cos theta * cos phi, -sin theta * sin phi, x - x_c
		,   0, rho,   0,                    0,             -cos phi, y - y_c
		,   0,   0, rho, -sin theta * cos phi, -cos theta * sin phi, z - z_c ])
	
	xxzz = h_x*h_x + h_z*h_z
	e1' = scale (h_z / xxzz) h_x' - scale (h_x / xxzz) h_z'
	e2' = scale (-sqrt xxzz / (xxzz + h_y*h_y)) h_y' +
	      scale (h_y / (xxzz + h_y*h_y) / sqrt xxzz) 
			(scale h_x h_x' + scale h_z h_z')



-- | Measurement equation jacobian with respect to the camera.
-- TODO Optimize: give it a pre-computed camera rotation matrix and its derivatives.
-- All matrices are generated by Sage Mathematics. The surrounding maths is
-- computed by hand. The whole routine is verified by a monte-carlo test.
jacobian_c :: GaussianCamera -> Vector Double -> Matrix Double
jacobian_c (GaussianCamera mu _) f = fromRows [e1', e2'] where
	rho = f @> 5
	[c_x, c_y, c_z, alpha, beta, gamma] = toList mu
	
	sa = sin alpha; sb = sin beta; sg = sin gamma;
	ca = cos alpha; cb = cos beta; cg = cos gamma; 
	
	cpos = (3|> [c_x,c_y,c_z])
	crot = (3><3) -- yaw, pitch, roll to a rotation matrix
		[  sa*sb*sg + ca*cg, -cg*sa*sb + ca*sg, -cb*sa
		,            -cb*sg,             cb*cg,    -sb
		, -ca*sb*sg + cg*sa,  ca*cg*sb + sa*sg,  ca*cb ]
		
	[h_x, h_y, h_z] = toList $ measure_h (ExactCamera cpos crot) f
	[h_x', h_y', h_z'] = toRows h'

	dR_da = (3><3)
		[ ca*sb*sg - cg*sa, -ca*cg*sb - sa*sg, -ca*cb
		,                0,                 0,      0
		, sa*sb*sg + ca*cg, -cg*sa*sb + ca*sg, -cb*sa ]
	dR_db = (3><3)
		[ cb*sa*sg, -cb*cg*sa,  sa*sb
		,    sb*sg,    -cg*sb,    -cb
		, -ca*cb*sg, ca*cb*cg, -ca*sb ]
	dR_dg = (3><3)
		[  cg*sa*sb - ca*sg,  sa*sb*sg + ca*cg, 0
		,            -cb*cg,            -cb*sg, 0
		, -ca*cg*sb - sa*sg, -ca*sb*sg + cg*sa, 0 ]

	g' = asColumn $ measure_g cpos f
	h' = (trans crot <> scale (-rho) (ident 3)) ! (trans dR_da <> g') ! (trans dR_db <> g') ! (trans dR_dg <> g')
	
	xxzz = h_x*h_x + h_z*h_z
	e1' = scale (h_z / xxzz) h_x' - scale (h_x / xxzz) h_z'
	e2' = scale (-sqrt xxzz / (xxzz + h_y*h_y)) h_y' +
	      scale (h_y / (xxzz + h_y*h_y) / sqrt xxzz) 
			(scale h_x h_x' + scale h_z h_z')


