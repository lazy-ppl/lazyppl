module TestMala where
import AD
import Data.Colour
import Data.Colour.Names
import Control.Monad
import Data.Number.Erf
import LazyPPLHMC

import Debug.Trace

import Graphics.Matplotlib hiding (density)

normal m s = do { x <- stdnormal ; return $ s * x + m }

linear :: Floating d => Prob d (d -> d)
linear =
  do
    a <- normal 0 3
    b <- normal 0 3
    let f = \x -> a * x + b
    return f

plotLinearPrior =
  do
    fs' <- mh (grwKernel 0.2) (sample linear) 
    let fs = map (\f -> primal . f . toNagata) $ take 1000 $ every 100 $ fs'
    plotFuns "images/mala-linear-prior.png" [] fs 0.1

dataset :: Floating d => [(d, d)]
dataset = [(0,0.6), (1, 0.7), (2,1.2), (3,3.2), (4,6.8), (5, 8.2), (6,8.4)]

plotDataset =
  do
    plotFuns "images/regression-dataset.png" dataset [] 0.1

normalPdf :: Floating d => d -> d -> d -> d
normalPdf m s x = let x' = (x - m)/s in  exp (negate (x' * x') / 2) / (sqrt (2 * pi)*s)

normalLogPdf :: Floating d => d -> d -> d -> d
normalLogPdf m s x = let x' = (x - m)/s in negate (x' * x') / 2 - (log (sqrt (2 * pi)*s))

regress :: (Floating d,Show d,Show a) => d -> Prob d (a -> d) -> [(a, d)] -> Meas d (a -> d)
regress sigma prior dataset =
  do
    f <- sample prior
    --forM_ dataset (\(x, y) -> scoreLog $ traceShow (normalLogPdf (f x) sigma y,x,y) $ normalLogPdf (f x) sigma y)
    forM_ dataset (\(x, y) -> scoreLog $ (normalLogPdf (f x) sigma y))
    return f

plotLinReg =
  do fs' <- mh (hmcKernel (LFConfig 0.001 10 0)) (regress (toNagata 0.5) linear dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 1000 fs'
     plotFuns "images/mala/hmc-linear-reg.png" dataset fs 0.05
     fs' <- mh (malaKernel 0.0005) (regress (toNagata 0.5) linear dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 500 $ fs'
     plotFuns "images/mala/mala-linear-reg.png" dataset fs 0.05
     fs' <- mh (grwKernel 0.1) (regress (toNagata 0.5) linear dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 500 $ fs'
     plotFuns "images/mala/grw-linear-reg.png" dataset fs 0.05
     fs' <- mh (lmhKernel 0.5) (regress (toNagata 0.5) linear dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 500 $ fs'
     plotFuns "images/mala/lmh-linear-reg.png" dataset fs 0.05
     
  
plotLinRegHMC (eps, steps) = 
  do fs' <- mh (hmcKernel (LFConfig eps steps 0)) (regress (toNagata 0.5) linear dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 1000 $ fs'
     let name = "images/mala/hmc-linear-reg-eps-" ++ show eps ++ "steps-" ++ show steps ++ ".png"
     --print ("done with eps: " ++ show eps ++ " steps: " ++ show steps)
     plotFuns name dataset fs 0.02 

plotLinRegHMCAll =
  do let configs = [(e, s) | e <- [0.00001, 0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05], s <- [1, 5, 10, 15, 20]]
     let configs = [(0.001, 10)]
     let x = map plotLinRegHMC configs
     sequence_ x


exponential :: Erf d => d -> Prob d d
exponential rate = do 
  x <- uniform
  return $ - (log x / rate)

-- Poisson point process that extends infinitely in one dimension.
-- Defined by stepping using exponential distribution.
poissonPP :: Erf d => d -> d -> Prob d [d]
poissonPP lower rate =
  do
    step <- exponential rate
    let x = lower + step
    xs <- poissonPP x rate
    return (x : xs)


splice :: Ord d => Prob d [d] -> Prob d (d -> d) -> Prob d (d -> d)
splice pointProcess randomFun =
  do
    xs <- pointProcess
    fs <- mapM (const randomFun) xs
    default_f <- randomFun
    let -- h :: [(d, d -> d)] -> d -> d
        h [] x = default_f x
        h ((a, f) : xfs) x | x <= a = f x
        h ((a, f) : xfs) x | x > a = h xfs x
    return (h (zip xs fs))

randConst :: Num d => Prob d (d -> d)
randConst =
  do
    b <- normal 0 3
    let f = \x -> b
    return f

plotStepReg =
  -- eps, steps = (0.0005, 25), (0.005, 30), (0.005, 20)
  do fs' <- mh (hmcKernel (LFConfig 0.005 30 0)) (regress (toNagata 0.5) (splice (poissonPP 0 0.2) randConst) dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 2000 fs'
     plotFuns "images/mala/hmc-piecewiseconst-reg.png" dataset fs 0.02 
     fs' <- mh (malaKernel 0.0005) (regress (toNagata 0.5) (splice (poissonPP 0 0.2) randConst) dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 2000 fs'
     plotFuns "images/mala/mala-piecewiseconst-reg.png" dataset fs 0.02
     fs' <- mh (grwKernel 0.1) (regress (toNagata 0.5) (splice (poissonPP 0 0.2) randConst) dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 2000 $ fs'
     plotFuns "images/mala/grw-piecewiseconst-reg.png" dataset fs 0.01
     fs' <- mh (lmhKernel 0.5) (regress (toNagata 0.5) (splice (poissonPP 0 0.2) randConst) dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 2000 $ fs'
     plotFuns "images/mala/lmh-piecewiseconst-reg.png" dataset fs 0.02
     

plotStepRegHMC (eps, steps) = 
  do fs' <- mh (hmcKernel (LFConfig eps steps 0)) (regress (toNagata 0.5) (splice (poissonPP 0 0.2) randConst) dataset)
     let fs = map (\f -> primal . f . toNagata) $ take 2000 $ drop 1000 fs'
     let name = "images/mala/hmc-piecewiseconst-reg-eps-" ++ show eps ++ "steps-" ++ show steps ++ ".png"
     --print ("done with eps: " ++ show eps ++ " steps: " ++ show steps)
     plotFuns name dataset fs 0.02 

plotStepRegHMCAll =
  do let configs = [(e, s) | e <- [0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5], s <- [15, 20, 25, 30, 35, 40]]
     let configs = [ (0.005, 15),  (0.005, 20), (0.005, 25), (0.005, 30), (0.001, 15),  (0.001, 20), (0.001, 25), (0.001, 30)]
     let configs = [(0.05, 50)]
     let x = map plotStepRegHMC configs
     sequence_ x


-- eps = 0.05, steps = 40
plotStepRegLAHMC (eps, steps, chances, alpha, i) = 
  do fs' <- lahmcPersistence (lookaheadHMC chances) (regress (toNagata 0.5) (splice (poissonPP 0 0.2) randConst) dataset) (LFConfig eps steps 0) alpha
     let fs = map (\f -> primal . f . toNagata) $ take 5000 $ drop 0 fs'
     let y = map (\x -> map (fs!!x) [0..20]) $ 0:[100, 200..1900]
     print y
     let name = "images/mala/hmc-piecewiseconst-reg-eps-" ++ show eps ++ "steps-" ++ show steps ++ "chances-" ++ show chances ++ "alpha-" ++ show alpha ++ "("++ show i ++ ").png"
     --print ("done with eps: " ++ show eps ++ " steps: " ++ show steps)
     plotFuns name dataset fs 0.02 

plotStepRegLAHMCAll =
  do let configs = [(e, s) | e <- [0.00005, 0.0001, 0.0005, 0.001, 0.005, 0.01, 0.05, 0.1, 0.5], s <- [15, 20, 25, 30, 35, 40]]
     let configs = [ (0.005, 15),  (0.005, 20), (0.005, 25), (0.005, 30), (0.001, 15),  (0.001, 20), (0.001, 25), (0.001, 30)]
     --let configs = [(0.005, 20, 3, 0.5, x) | x<- [1..10]]
     let configs = [(0.05, 50, 9, 0.5, x) | x<- [1..30]]
     let x = map plotStepRegLAHMC configs
     sequence_ x

{--

splice :: Prob [Double] -> Prob (Double -> Double) -> Prob (Double -> Double)
splice pointProcess randomFun =
  do
    xs <- pointProcess
    fs <- mapM (const randomFun) xs
    default_f <- randomFun
    let h :: [(Double, Double -> Double)] -> Double -> Double
        h [] x = default_f x
        h ((a, f) : xfs) x | x <= a = f x
        h ((a, f) : xfs) x | x > a = h xfs x
    return (h (zip xs fs))
\end{code}

Note that this second-order function works for any point process and for any random function. We will use the random linear function `linear`, and for a point process we will use the following Poisson point process, `poissonPP`. This generates an infinite random list of points, where the gaps between them are exponentially distributed.
\begin{code}
poissonPP :: Double -> Double -> Prob [Double]
poissonPP lower rate =
  do
    step <- exponential rate
    let x = lower + step
    xs <- poissonPP x rate
    return (x : xs)
\end{code}
Here are five draws from the process. Each draw is really an infinite set of points, but we have truncated the display to the viewport [0,20]. Laziness then takes care of truncating the infinite sequences appropriately.
![](images/regression-poissonpp.png)
<details class="code-details">
<summary>(Plotting code)</summary>
\begin{code}
plotPoissonPP =
  do
    pws <- mh 1 $ sample $ poissonPP 0 0.1
    let ps = map (takeWhile (20>)) $ map fst $ take 5 $ pws
    let filename = "images/regression-poissonpp.png"
    putStrLn $ "Plotting " ++ filename ++ "..."
    let myscatter mpl i = mpl % setSubplot i % scatter (ps !! i) (map (const (0::Double)) (ps !! i)) @@ [o2 "s" (10::Int),o2 "c" "black"]  % xlim (0::Int) (20::Int) % ylim (-1 :: Int) (1::Int) % mp # "ax.yaxis.set_major_formatter(mticker.NullFormatter())"
    let myscatteraxes mpl i = if i < (length ps - 1) then myscatter mpl i % mp # "ax.xaxis.set_major_formatter(mticker.NullFormatter())" else myscatter mpl i
    file filename $ foldl myscatteraxes (subplots @@ [o2 "nrows" (length ps),o2 "ncols" (1::Int)]) [0..(length ps - 1)]
    putStrLn $ "Done."
\end{code}
</details>
<br></br>

We can now invoke a random piecewise linear function by calling `splice (poissonPP 0 0.1) linear`{.haskell}. 
Here are ten draws from this distribution. Because the viewport is bounded, laziness takes care of truncations to the point process that we passed to `splice`.

![](images/regression-piecewise-prior.png)

<details class="code-details">
<summary>(Plotting code)</summary>
\begin{code}
plotPiecewisePrior =
  do
    fs' <- mh 1 $ sample $ splice (poissonPP 0 0.1) linear
    let fs = map fst $ take 10 $ fs'
    plotFuns "images/regression-piecewise-prior.png" [] fs 1
\end{code}
</details>
<br></br>
This is a random function just like any other, so we can use it as a prior, using the same regression routines as before, `regress 0.1 (splice (poissonPP 0 0.1) linear)`{.haskell}. We can then sample from the unnormalized distribution using Metropolis-Hastings.
\begin{code}
plotPiecewiseReg =
  do
    fs' <- mhirreducible 0.2 0.1 (regress 0.1 (splice (poissonPP 0 0.1) linear) dataset)
    let fs = map fst $ take 1000 $ every 1000 $ drop 10000 fs'
    plotFuns "images/regression-piecewise-reg.png" dataset fs 0.01
\end{code}
![](images/regression-piecewise-reg.png)

Finally, we can also do our regression using piecewise constant functions. Our prior will now be `randConst`{.haskell}, a random linear function with slope 0.
\begin{code}
randConst :: Prob (Double -> Double)
randConst =
  do
    b <- normal 0 3
    let f = \x -> b
    return f
\end{code}
Using the same recipe as before, we can construct our prior by calling `splice (poissonPP 0 0.1) randConst`{.haskell} and perform inference on it to get the resultant unnormalized distribution of piecewise constant functions.
\begin{code}
plotPiecewiseConst =
  do
    fs' <- mhirreducible 0.2 0.1 (regress 0.1 (splice (poissonPP 0 0.1) randConst) dataset)
    let fs = map fst $ take 1000 $ every 1000 $ drop 10000 fs'
    plotFuns "images/regression-piecewise-const.png" dataset fs 0.01
\end{code}
![](images/regression-piecewise-const.png)


<details class="code-details">
<summary>Graphing routines</summary>
\begin{code}--}
-- Plot the points drawn from weighted samples
-- epsilon: smallest y axis difference to worry about
-- delta: smallest x axis difference to worry about
interestingPoints :: (Double -> Double) -> Double -> Double -> Double -> Double -> [Double] -> [Double]
interestingPoints f lower upper epsilon delta acc =
  if abs(upper - lower) < delta then acc
  else
    let mid = (upper - lower) / 2 + lower in
    if abs((f(upper) - f(lower)) / 2 + f(lower) - f(mid)) < epsilon
    then acc
    else interestingPoints f lower mid epsilon delta (mid : (interestingPoints f mid upper epsilon delta acc))

sampleFun f =
--  [ (x, f x) | x <- [(-0.25),(-0.25+0.1)..6.2]]
  let xs = ((-0.25) : (interestingPoints f (-0.25) 6.2 0.3 0.001 [6.2])) in
  map (\x -> (x,f x)) xs


plotFuns :: String -> [(Double,Double)] -> [Double -> Double] -> Double -> IO ()
plotFuns filename dataset funs alpha = 
    do  putStrLn $ "Plotting " ++ filename ++ "..."
        file filename $ foldl (\a f -> let xfs = sampleFun f in a % plot (map fst xfs) (map snd xfs) @@ [o1 "go-", o2 "linewidth" (0.5 :: Double), o2 "alpha" alpha, o2 "ms" (0 :: Int)]) (scatter (map fst dataset) (map snd dataset) @@ [o2 "c" "black"] % xlim (0 :: Int) (6 :: Int) % ylim (-2 :: Int) (10 :: Int)) funs
        putStrLn "Done."
        return ()


-- main :: IO ()
-- main = do {plotLinearPrior ; plotDataset ; plotLinReg ; plotPiecewisePrior ; plotPoissonPP ; plotPiecewiseReg ; plotPiecewiseConst }

main :: IO ()
main = plotStepRegHMCAll