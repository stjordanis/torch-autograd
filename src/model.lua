-- standard models
local model = {}

-- nn modules:
local nn = require('autograd.nnwrapper')('nn')

-- util
local util = require 'autograd.util'
local node = require 'autograd.node'
local getValue = node.getValue

-- generic generator, from sequential list of layers:
local function sequence(layers, layer2params)
   return function(params, input)
      for i,layer in ipairs(layers) do
         local paramsi = layer2params[i]
         if paramsi then
            input = layer(input, params[paramsi].W, params[paramsi].b)
         else
            input = layer(input)
         end
      end
      return input
   end
end

function model.NeuralLayer(opt, params, layers, layer2params)
   -- options:
   opt = opt or {}
   local inputFeatures = opt.inputFeatures or 3
   local outputFeatures = opt.outputFeatures or 16
   local batchNormalization = opt.batchNormalization or false
   local dropoutProb = opt.dropoutProb or 0
   local activations = opt.activations

   -- container
   layers = layers or {}
   params = params or {}
   layer2params = layer2params or {}

   -- dropout:
   if dropoutProb > 0 then
      table.insert(layers, nn.Dropout(dropoutProb))
   end

   -- linear layer:
   table.insert(layers, nn.Linear(inputFeatures, outputFeatures))
   table.insert(params, {
      W = torch.zeros(outputFeatures, inputFeatures),
      b = torch.zeros(outputFeatures),
   })
   layer2params[#layers] = #params

   -- batch normalization:
   if batchNormalization then
      table.insert(layers, nn.BatchNormalization(outputFeatures))
      table.insert(params, {
         W = torch.zeros(outputFeatures),
         b = torch.zeros(outputFeatures),
      })
      layer2params[#layers] = #params
   end

   -- activations:
   if opt.activations then
      table.insert(layers, nn[activations]())
   end

   -- layers
   return sequence(layers, layer2params), params, layers
end

function model.NeuralNetwork(opt, params, layers, layer2params)
   -- options:
   opt = opt or {}
   local inputFeatures = opt.inputFeatures or 10
   local hiddenFeatures = opt.hiddenFeatures or {100,2}
   local batchNormalization = opt.batchNormalization or false
   local dropoutProb = opt.dropoutProb or 0
   local dropoutProbs = opt.dropoutProbs or {}
   local activations = opt.activations or 'ReLU'
   local classifier = opt.classifier or false

   -- container
   layers = layers or {}
   params = params or {}
   layer2params = layer2params or {}

   -- always add a reshape to force input dim:
   table.insert(layers, nn.Reshape(inputFeatures))

   -- add layers:
   for i,hiddens in ipairs(hiddenFeatures) do
      if classifier and i == #hiddenFeatures then
         activations = nil
         batchNormalization = nil
      end
      model.NeuralLayer({
         inputFeatures = inputFeatures,
         outputFeatures = hiddens,
         dropoutProb = dropoutProbs[i] or dropoutProb,
         activations = activations,
         batchNormalization = batchNormalization,
      }, params, layers, layer2params)
      inputFeatures = hiddens
   end

   -- layers
   return sequence(layers, layer2params), params, layers
end

function model.SpatialLayer(opt, params, layers, layer2params)
   -- options:
   opt = opt or {}
   local kernelSize = opt.kernelSize or 5
   local padding = opt.padding or math.ceil(kernelSize-1)/2
   local inputFeatures = opt.inputFeatures or 3
   local outputFeatures = opt.outputFeatures or 16
   local batchNormalization = opt.batchNormalization or false
   local dropoutProb = opt.dropoutProb or 0
   local activations = opt.activations
   local pooling = opt.pooling or 1
   local inputStride = opt.inputStride or 1

   -- container
   layers = layers or {}
   params = params or {}
   layer2params = layer2params or {}

   -- stack modules:
   if dropoutProb > 0 then
      table.insert(layers, nn.SpatialDropout(dropoutProb) )
   end
   table.insert(layers, nn.SpatialConvolutionMM(inputFeatures, outputFeatures, kernelSize, kernelSize, inputStride, inputStride, padding, padding) )
   do
      table.insert(params, {
         W = torch.zeros(outputFeatures, inputFeatures*kernelSize*kernelSize),
         b = torch.zeros(outputFeatures),
      })
      layer2params[#layers] = #params
   end
   if batchNormalization then
      table.insert(layers, nn.SpatialBatchNormalization(outputFeatures) )
      do
         table.insert(params, {
            W = torch.zeros(outputFeatures),
            b = torch.zeros(outputFeatures),
         })
         layer2params[#layers] = #params
      end
   end
   if opt.activations then
      table.insert(layers, nn[activations]())
   end
   if pooling > 1 then
      table.insert(layers, nn.SpatialMaxPooling(pooling, pooling) )
   end

   -- layers
   return sequence(layers, layer2params), params, layers
end

function model.SpatialNetwork(opt, params, layers, layer2params)
   -- options:
   opt = opt or {}
   local kernelSize = opt.kernelSize or 5
   local padding = opt.padding
   local inputFeatures = opt.inputFeatures or 3
   local hiddenFeatures = opt.hiddenFeatures or {16,32,64}
   local batchNormalization = opt.batchNormalization or false
   local dropoutProb = opt.dropoutProb or 0
   local dropoutProbs = opt.dropoutProbs or {}
   local activations = opt.activations or 'ReLU'
   local poolings = opt.poolings or {1,1,1}
   local inputStride = opt.inputStride or 1

   -- container
   layers = layers or {}
   params = params or {}
   layer2params = layer2params or {}

   -- add layers:
   for i,hiddens in ipairs(hiddenFeatures) do
      model.SpatialLayer({
         inputStride = inputStride,
         inputFeatures = inputFeatures,
         outputFeatures = hiddens,
         pooling = poolings[i],
         dropoutProb = dropoutProbs[i] or dropoutProb,
         activations = activations,
         batchNormalization = batchNormalization,
         kernelSize = kernelSize,
         padding = padding,
         cuda = cuda,
      }, params, layers, layer2params)
      inputFeatures = hiddens
      inputStride = 1
   end

   -- layers
   return sequence(layers, layer2params), params, layers
end

function model.RecurrentNetwork(opt, params)
   -- options:
   opt = opt or {}
   local inputFeatures = opt.inputFeatures or 10
   local hiddenFeatures = opt.hiddenFeatures or 100
   local outputType = opt.outputType or 'last' -- 'last' or 'all'

   -- container:
   params = params or {}

   -- parameters:
   local p = {
      Wx = torch.zeros(inputFeatures, hiddenFeatures),
      bx = torch.zeros(1, hiddenFeatures),
      Wh = torch.zeros(hiddenFeatures, hiddenFeatures),
      bh = torch.zeros(1, hiddenFeatures),
   }
   table.insert(params, p)

   -- function:
   local f = function(params, x)
      -- dims:
      local p = params[1] or params
      if getValue(x):dim() == 2 then
         x = torch.view(x, 1, getValue(x):size(1), getValue(x):size(2))
      end
      local batch = getValue(x):size(1)
      local steps = getValue(x):size(2)

      -- hiddens:
      local hs = {}

      -- go over time:
      for t = 1,steps do
         -- xt
         local xt = torch.select(x,2,t)

         -- dot prods:
         local hx = xt * p.Wx + torch.expand(p.bx, batch, hiddenFeatures)
         local hh
         if t > 1 then
            hh = hs[t-1] * p.Wh + torch.expand(p.bh, batch, hiddenFeatures)
         else
            hh = torch.expand(p.bh, batch, hiddenFeatures)
         end
         hs[t] = torch.tanh(hx+hh)
      end

      -- output:
      if outputType == 'last' then
         -- return last hidden code:
         return hs[#hs]
      else
         -- return all:
         for i in ipairs(hs) do
            hs[i] = torch.view(hs[i], batch,1,-1)
         end
         return torch.cat(hs,2)
      end
   end

   -- layers
   return f, params
end

function model.RecurrentLSTMNetwork(opt, params)
   -- options:
   opt = opt or {}
   local inputFeatures = opt.inputFeatures or 10
   local hiddenFeatures = opt.hiddenFeatures or 100
   local outputType = opt.outputType or 'last' -- 'last' or 'all'

   -- container:
   params = params or {}

   -- parameters:
   local p = {
      Wx = torch.zeros(inputFeatures, 4 * hiddenFeatures),
      bx = torch.zeros(1, 4 * hiddenFeatures),
      Wh = torch.zeros(hiddenFeatures, 4 * hiddenFeatures),
      bh = torch.zeros(1, 4 * hiddenFeatures),
   }
   table.insert(params, p)

   -- function:
   local f = function(params, x, prevState)
      -- dims:
      local p = params[1] or params
      if getValue(x):dim() == 2 then
         x = torch.view(x, 1, getValue(x):size(1), getValue(x):size(2))
      end
      local batch = getValue(x):size(1)
      local steps = getValue(x):size(2)

      -- hiddens:
      local hs = {}
      local cs = {}

      -- go over time:
      for t = 1,steps do
         -- xt
         local xt = torch.select(x,2,t)

         -- pack all dot products:
         local hx = xt * p.Wx + torch.expand(p.bx, batch, 4*hiddenFeatures)
         local hh
         if t > 1 then
            hh = hs[t-1] * p.Wh + torch.expand(p.bh, batch, 4*hiddenFeatures)
         elseif prevState then
            hh = prevState.h * p.Wh + torch.expand(p.bh, batch, 4*hiddenFeatures)
         else
            hh = torch.expand(p.bh, batch, 4*hiddenFeatures)
         end
         local sums = torch.view(hx+hh, batch, 4, hiddenFeatures)

         -- batch compute gates:
         local sigmoids = util.sigmoid( torch.narrow(sums, 2,1,3) )
         local inputGate = torch.select(sigmoids, 2,1)
         local forgetGate = torch.select(sigmoids, 2,2)
         local outputGate = torch.select(sigmoids, 2,3)

         -- write inputs
         local tanhs = torch.tanh( torch.narrow(sums, 2,4,1) )
         local inputValue = torch.select(tanhs, 2,1)

         -- partial gatings:
         if t > 1 then
            cs[t] = torch.cmul(forgetGate, cs[t-1]) + torch.cmul(inputGate, inputValue)
         elseif prevState then
            cs[t] = torch.cmul(forgetGate, prevState.c) + torch.cmul(inputGate, inputValue)
         else
            cs[t] = torch.cmul(inputGate, inputValue)
         end

         -- next h
         hs[t] = torch.cmul(outputGate, torch.tanh(cs[t]))
      end

      -- save state
      -- TODO: we need getValue here to cut tensors from the tape - would be best
      -- if hidden from the user
      local newState = {h=getValue(hs[#hs]), c=getValue(cs[#cs])}

      -- output:
      if outputType == 'last' then
         -- return last hidden code:
         return hs[#hs], newState
      else
         -- return all:
         for i in ipairs(hs) do
            hs[i] = torch.view(hs[i], batch,1,-1)
         end
         return torch.cat(hs,2), newState
      end
   end

   -- layers
   return f, params
end

return model
