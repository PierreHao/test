from proto import caffe_pb2
from google.protobuf import text_format
import ctypes
from pvanet import lib as pvalib

name = '../pvanet/9.0.0_mod1_tuned/9.0.0_mod1.custom.pt'
#name = 'faster_rcnn_train.pt'

proto = caffe_pb2.NetParameter()
f = open(name, 'r')
text_format.Merge(f.read(), proto)
f.close()

net = pvalib._net()
net_phase = 1

def test():
  print proto.name
  for i, layer in enumerate(proto.layer):
    print 'Layer {:d}: {:s}, {:s}, {:s}'.format(i, layer.name, layer.type, layer.top)
    if layer.convolution_param:
      print 'stride = {:f}'.format(layer.convolution_param.stride)
    if layer.param:
      try:
        print 'lr_mult = {:f}'.format(layer.param[0].lr_mult)
        print 'decay_mult = {:f}'.format(layer.param[0].decay_mult)
        print 'lr_mult = {:f}'.format(layer.param[1].lr_mult)
        print 'decay_mult = {:f}'.format(layer.param[1].decay_mult)
      except:
        None
    if layer.include:
      try:
        if layer.include[0].phase:
          print 'phase = train'
        else:
          print 'phase = test'
      except:
        None

def parse_layer(layer, phase=1):
  def convert_name(name):
    if len(name) == 0:
      return None
    return str(name).replace('/', '_')
  def convert_names(names):
    return [convert_name(name) for name in names]

  layer_name = convert_name(layer.name)
  bottom_names = convert_names(layer.bottom)
  top_names = convert_names(layer.top)
  param_names = convert_names([elem.name for elem in layer.param])

  print '{:s}, {:s}'.format(layer_name, layer.type)
  print '  bottom: {:s}'.format(bottom_names)
  print '  top: {:s}'.format(top_names)
  print '  param: {:s}'.format(param_names)

  if layer.type == 'DummyData':
    pvalib.add_data_layer(net, layer_name, top_names[0], top_names[1])
  elif layer.type == 'Convolution' or layer.type == 'Deconvolution':
    option = layer.convolution_param
    group = option.group if option.group > 0 else 1
    num_output = option.num_output
    kernel_h = max(option.kernel_h, option.kernel_size)
    kernel_w = max(option.kernel_w, option.kernel_size)
    stride_h = max(option.stride_h, option.stride)
    stride_w = max(option.stride_w, option.stride)
    pad_h = max(option.pad_h, option.pad)
    pad_w = max(option.pad_w, option.pad)
    bias_term = option.bias_term
    print [group, kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w, bias_term]
    if layer.type == 'Convolution':
      pvalib.add_conv_layer(net, layer_name, bottom_names[0], top_names[0], None, None, group, num_output, kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w, bias_term, 0)
    else:
      pvalib.add_deconv_layer(net, layer_name, bottom_names[0], top_names[0], None, None, group, num_output, kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w, bias_term, 0)
  elif layer.type == 'Power':
    option = layer.power_param
    weight = float(option.scale)
    bias = float(option.shift)
    print [weight, bias]
    pvalib.add_scale_const_layer(net, layer_name, bottom_names[0], top_names[0], weight, bias, 1)
  elif layer.type == 'Concat':
    name_len = pvalib._max_name_len()
    buffers = [ctypes.create_string_buffer(name_len) for i in range(len(bottom_names))]
    for buf, name in zip(buffers, bottom_names):
      buf[:len(name)] = name[:]
      buf[len(name)] = '\0'
    pointers = (ctypes.c_char_p * len(bottom_names))(*map(ctypes.addressof, buffers))
    pvalib.add_concat_layer(net, layer_name, pointers, top_names[0], len(bottom_names))
  elif layer.type == 'ReLU':
    pvalib.add_relu_layer(net, layer_name, bottom_names[0], top_names[0], 0)
  elif layer.type == 'Pooling':
    option = layer.pooling_param
    kernel_h = max(option.kernel_h, option.kernel_size)
    kernel_w = max(option.kernel_w, option.kernel_size)
    stride_h = max(option.stride_h, option.stride)
    stride_w = max(option.stride_w, option.stride)
    pad_h = max(option.pad_h, option.pad)
    pad_w = max(option.pad_w, option.pad)
    print [kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w]
    pvalib.add_pool_layer(net, layer_name, bottom_names[0], top_names[0], kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w)
  elif layer.type == 'Scale':
    option = layer.scale_param
    bias_term = option.bias_term
    print [bias_term]
    pvalib.add_scale_channel_layer(net, layer_name, bottom_names[0], top_names[0], None, None, bias_term)
  elif layer.type == 'Eltwise':
    name_len = pvalib._max_name_len()
    buffers = [ctypes.create_string_buffer(name_len) for i in range(len(bottom_names))]
    for buf, name in zip(buffers, bottom_names):
      buf[:len(name)] = name[:]
      buf[len(name)] = '\0'
    pointers = (ctypes.c_char_p * len(bottom_names))(*map(ctypes.addressof, buffers))
    pvalib.add_eltwise_layer(net, layer_name, pointers, top_names[0], len(bottom_names))
  else:
    'Undefined type'

def parse_proto():
  for i, layer in enumerate(proto.layer):
    def skip(i, layer):
      if len(layer.include) > 0 and all([elem.phase != net_phase for elem in layer.include]):
        return True
      if layer.type in ['BatchNorm']:
        return True
      if layer.type == 'Scale' and i > 0 and proto.layer[i - 1].type == 'BatchNorm':
        return True
      return False

    if not skip(i, layer):
      parse_layer(layer)

parse_proto()
pvalib.setup_frcnn(net, 'convf_rpn', 'convf', 384, 3, 3, 512, 512)
net.contents.param_path = '../temp'
#pvalib.setup_inception(net)
#pvalib.setup_frcnn(net, 'convf', 'convf', 256, 1, 1, 512, 128)
#pvalib.get_tensor_by_name(net, 'conv1').contents.data_type = 1
#pvalib.get_tensor_by_name(net, 'conv3').contents.data_type = 1
#net.contents.param_path = '../data/temp5'
pvalib.shape_net(net)
pvalib.malloc_net(net)
pvalib.init_layers(net)

from scipy.ndimage import imread
img = imread('../dl/scripts/voc/000004.jpg')
pvalib._detect_net(img.tobytes(), img.shape[1], img.shape[0])
