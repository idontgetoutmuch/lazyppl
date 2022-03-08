{-# LANGUAGE ExtendedDefaultRules #-}
{-# LANGUAGE ScopedTypeVariables #-}


module Clustering where

import Control.Lens
import Data.Colour
import Data.Colour.Names
import Data.Colour.RGBSpace.HSV
import Data.Colour.SRGB
import Data.Default.Class
import Data.List
import Data.Monoid
import Distr
import Distr.DirichletP
import Distr.Memoization
import LazyPPL
import Numeric.Log

import Graphics.Matplotlib hiding (density)


type RgbColor = Double

{- | A generic Chinese-Restaurant clustering program
    Takes pparam :: Prob b, a distribution on parameters
          like :: b -> a -> Double, parameterized likelihood function \
    Tags each point with a colour describing the cluster it is in -}
cluster :: [a] -> Prob b -> (b -> a -> Double) -> Meas [(a, RgbColor, b)]
cluster xs pparam like =
  do
    rest <- sample $ newRestaurant 0.3
    param <- sample $ memoize $ const pparam
    color <- sample $ memoize $ const $ uniformbounded 0.2 1
    mapM
      ( \x -> do
          i <- sample $ newCustomer rest
          score $ like (param i) x
          return (x, color i, param i)
      )
      xs





-- | Example 2d data set
dataset = [(7.7936387, 7.469271), (5.3105156, 7.891521), (5.4320135, 5.135559), (7.3844196, 7.478719), (6.7382938, 7.476735), (0.6663453, 4.460257), (3.2001898, 2.653919), (2.1231227, 3.758051), (3.3734472, 2.420528), (0.4699408, 1.835277)]

-- | 'nnormal' is a normal distribution but it uses two seeds,
-- | so perhaps it moves around a little more
-- | and it takes up more time in the single-site MH.
nnormal x s = do x1 <- normal x ((sqrt 15 * s * s) / 4); x2 <- normal 0 (s / 4); return $ x1 + x2

{- | Example of using the clustering program.
    Here the parameters are the x and y coordinates
    and standard deviation of the cluster -}
example :: Meas [((Double, Double), RgbColor, (Double, Double, Double))]
example =
  cluster
    dataset
    (do x <- nnormal 5 4; y <- nnormal 5 4; prec <- gamma 2 4; return (x, y, 1 / sqrt prec))
    (\(x, y, s) (x', y') -> normalPdf x s x' * normalPdf y s y')

test =
  do
    xycws' <- mh1 example
    let xycws = take 20000 xycws'
    let maxw = (maximum $ map snd xycws :: Product (Log Double))
    let (Just xyc) = Data.List.lookup maxw $ map (\(z, w) -> (w, z)) xycws
    plot_coords "clustering.svg" xyc

{-- GRAPHING ROUTINES --}
-- plot_coords :: String -> [((Double, Double), Double, (Double, Double, Double))] -> IO ()
-- plot_coords filename xycs = undefined
--    let my_areas = map (\((_,_),c,(x,y,sigma)) -> let rgb = hsv (c * 360) 0.2 1 in toPlot $ plot_points_style .~ filledCircles (sigma*70) (opaque $ sRGB (channelRed rgb) (channelGreen rgb) (channelBlue rgb))
--                        $ plot_points_values .~ [(x,y)]
--                        $ def) xycs in

--   let circle x y r = [((- r) * cos (a * 2 * pi / 360) + x, (r * sin (a * 2 * pi / 360) + y, (- r) * sin (a * 2 * pi / 360) + y)) | a <- [0, 0.5 .. 180 :: Double]]
--    in let my_areas =
--             map
--               ( \((_, _), c, (x, y, sigma)) ->
--                   let rgb = hsv (c * 360) 0.15 1
--                    in toPlot $
--                         plot_fillbetween_style .~ solidFillStyle (opaque $ sRGB (channelRed rgb) (channelGreen rgb) (channelBlue rgb)) $
--                           plot_fillbetween_values .~ (circle x y (2 * sigma)) $
--                             def
--               )
--               xycs
--        in let my_dots =
--                 map
--                   ( \((x, y), c, _) ->
--                       let rgb = hsv (c * 360) 1 1
--                        in toPlot $
--                             plot_points_style .~ filledCircles 4 (opaque $ sRGB (channelRed rgb) (channelGreen rgb) (channelBlue rgb)) $
--                               plot_points_values .~ [(x, y)] $
--                                 def
--                   )
--                   xycs
--            in let my_layout =
--                     layout_plots .~ (my_areas ++ my_dots) $
--                       layout_x_axis
--                         . laxis_generate
--                         .~ scaledAxis def (0, 10)
--                         $ layout_y_axis . laxis_generate .~ scaledAxis def (-2, 10) $
--                           def
--                in let graphic = toRenderable my_layout
--                    in do
--                         putStr ("Generating " ++ filename ++ "...")
--                         renderableToFile def filename graphic
--                         putStrLn (" Done!")
--                         return ()

plot_coords :: String -> [((Double, Double), RgbColor, (Double, Double, Double))] -> IO ()
plot_coords filename xycs = do 
  let (xs, ys) = unzip (map (\((x,y), _, _) -> (x, y)) xycs)
  let (allColours, allClusters) = unzip $ nub $ map (\(_, c, k) -> (c, k)) xycs
  let allClusters = map (\c -> map (\((x, y), _, _) -> (x, y)) $ 
                           filter (\(_, c', _) -> c == c') xycs)
                                allColours
  let clustersAndColours = zip (map unzip allClusters) allColours                       
  let plotSetup = figure @@ [o1 0]
       % setSizeInches 8 8 
       % axes @@ [o1 [0.1, 0.1, 0.65, 0.65]]
  let scatterings = foldl 
          (\p -> \((myxs, myys), mycolour) -> 
                        p % scatter myxs myys @@ [o2 "color" (show mycolour)]) 
            plotSetup
            $ clustersAndColours
  file filename scatterings
  putStrLn $ "generating " ++ filename ++ "... done."



main :: IO ()
main = do test
