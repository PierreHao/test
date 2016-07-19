from proto import caffe_pb2
from google.protobuf import text_format
import ctypes
from pvanet import lib as pvalib

def parse_layer(layer, generate, phase=1, verbose=False):
  def convert_name(name):
    if len(name) == 0:
      return None
    return str(name).replace('/', '_')

  def convert_names(names):
    return [convert_name(name) for name in names]

  def string_array(bottom_names):
    str_ary = 'const char* const names[] = { '
    for i in range(len(bottom_names) - 1):
      str_ary += '"{:s}", '.format(bottom_names[i])
    str_ary += '"{:s}" '.format(bottom_names[len(bottom_names) - 1])
    str_ary += '};'
    return str_ary

  command = ''

  layer_name = convert_name(layer.name)
  bottom_names = convert_names(layer.bottom)
  top_names = convert_names(layer.top)
  param_names = convert_names([elem.name for elem in layer.param])

  if verbose:
    print '{:s}, {:s}'.format(layer_name, layer.type)
    print '  bottom: {:s}'.format(bottom_names)
    print '  top: {:s}'.format(top_names)
    print '  param: {:s}'.format(param_names)

  if layer.type == 'DummyData':
    command = 'add_data_layer(net, "{:s}", "{:s}", "{:s}");'.format(layer_name, top_names[0], top_names[1])
    if generate:
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
    arg_str = '(net, "{:s}", "{:s}", "{:s}", NULL, NULL, {:d}, {:d}, {:d}, {:d}, {:d}, {:d}, {:d}, {:d}, {:d});'.format( \
              layer_name, bottom_names[0], top_names[0], group, num_output,
              kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w,
              bias_term)
    if layer.type == 'Convolution':
      command = 'add_conv_layer{:s}'.format(arg_str)
      if generate:
        pvalib.add_conv_layer(net, layer_name, bottom_names[0], top_names[0], None, None, group, num_output, kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w, bias_term)
    else:
      command = 'add_deconv_layer{:s}'.format(arg_str)
      if generate:
        pvalib.add_deconv_layer(net, layer_name, bottom_names[0], top_names[0], None, None, group, num_output, kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w, bias_term)

  elif layer.type == 'Power':
    option = layer.power_param
    weight = float(option.scale)
    bias = float(option.shift)
    command = 'add_scale_const_layer(net, "{:s}", "{:s}", "{:s}", {:f}, {:f}, 1);'.format( \
              layer_name, bottom_names[0], top_names[0], weight, bias)
    if generate:
      pvalib.add_scale_const_layer(net, layer_name, bottom_names[0], top_names[0], weight, bias, 1)

  elif layer.type == 'Concat':
    command += '{ '
    command += '{:s} '.format(string_array(bottom_names))
    command += 'add_concat_layer(net, "{:s}", names, "{:s}", {:d}); '.format( \
               layer_name, top_names[0], len(bottom_names))
    command += '}'
    if generate:
      name_len = pvalib._max_name_len()
      buffers = [ctypes.create_string_buffer(name_len) for i in range(len(bottom_names))]
      for buf, name in zip(buffers, bottom_names):
        buf[:len(name)] = name[:]
        buf[len(name)] = '\0'
      pointers = (ctypes.c_char_p * len(bottom_names))(*map(ctypes.addressof, buffers))
      pvalib.add_concat_layer(net, layer_name, pointers, top_names[0], len(bottom_names))

  elif layer.type == 'ReLU':
    command = 'add_relu_layer(net, "{:s}", "{:s}", "{:s}", 0);'.format( \
              layer_name, bottom_names[0], top_names[0])
    if generate:
      pvalib.add_relu_layer(net, layer_name, bottom_names[0], top_names[0], 0)

  elif layer.type == 'Pooling':
    option = layer.pooling_param
    kernel_h = max(option.kernel_h, option.kernel_size)
    kernel_w = max(option.kernel_w, option.kernel_size)
    stride_h = max(option.stride_h, option.stride)
    stride_w = max(option.stride_w, option.stride)
    pad_h = max(option.pad_h, option.pad)
    pad_w = max(option.pad_w, option.pad)
    arg_str = '(net, "{:s}", "{:s}", "{:s}", {:d}, {:d}, {:d}, {:d}, {:d}, {:d});'.format( \
              layer_name, bottom_names[0], top_names[0],
              kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w)
    command = 'add_max_pool_layer{:s}'.format(arg_str)
    if generate:
      pvalib.add_max_pool_layer(net, layer_name, bottom_names[0], top_names[0], kernel_h, kernel_w, stride_h, stride_w, pad_h, pad_w)

  elif layer.type == 'Scale':
    option = layer.scale_param
    bias_term = option.bias_term
    command = 'add_scale_channel_layer(net, "{:s}", "{:s}", "{:s}", NULL, NULL, {:d});'.format( \
              layer_name, bottom_names[0], top_names[0], bias_term)
    if generate:
      pvalib.add_scale_channel_layer(net, layer_name, bottom_names[0], top_names[0], None, None, bias_term)

  elif layer.type == 'Eltwise':
    command += '{ '
    command += '{:s} '.format(string_array(bottom_names))
    command += 'add_eltwise_layer(net, "{:s}", names, "{:s}", {:d}); '.format( \
               layer_name, top_names[0], len(bottom_names))
    command += '}'
    if generate:
      name_len = pvalib._max_name_len()
      buffers = [ctypes.create_string_buffer(name_len) for i in range(len(bottom_names))]
      for buf, name in zip(buffers, bottom_names):
        buf[:len(name)] = name[:]
        buf[len(name)] = '\0'
      pointers = (ctypes.c_char_p * len(bottom_names))(*map(ctypes.addressof, buffers))
      pvalib.add_eltwise_layer(net, layer_name, pointers, top_names[0], len(bottom_names))

  else:
    'Undefined type'
  return command

def parse_proto(proto, generate, phase=1):
  def skip(i, layer):
    if len(layer.include) > 0 and all([elem.phase != phase for elem in layer.include]):
      return True
    if layer.type in ['BatchNorm']:
      return True
    if layer.type == 'Scale' and i > 0 and proto.layer[i - 1].type == 'BatchNorm':
      return True
    return False

  command = '#include "layer.h"\n\n'
  command += 'void setup_shared_cnn(Net* const net)\n{\n'
  for i, layer in enumerate(proto.layer):
    if not skip(i, layer):
      command += '  {:s}\n'.format(parse_layer(layer, generate))
  command += '}\n'
  print command

def load_proto(proto_name):
  proto = caffe_pb2.NetParameter()
  f = open(proto_name, 'r')
  text_format.Merge(f.read(), proto)
  f.close()
  return proto

def load_pva900(generate=False):
  proto_name = '../pvanet/9.0.0_mod1_tuned/9.0.0_mod1.custom.pt'
  proto = load_proto(proto_name)
  parse_proto(proto, generate)

def load_pva33(generate=False):
  proto_name = '3.3.custom.pt'
  proto = load_proto(proto_name)
  parse_proto(proto, generate)


code_only = False
if code_only:
  print '---------------------- PVA 9.0.0 code ----------------------------'
  load_pva900()
  print '---------------------- PVA 3.3 code ----------------------------'
  load_pva33()
else:
  net = pvalib._net()
  pvalib.init_net(net)
  net.contents.param_path = '../data/pvanet/pvanet'
  net.contents.input_scale = 600
  load_pva900(generate=True)
  pvalib.setup_frcnn(net, 'convf_rpn', 'convf', 384, 3, 3, 1, 512, 512, 12000, 300)
  pvalib.shape_net(net)
  pvalib.malloc_net(net)
  from scipy.ndimage import imread
  img = imread('../dl/scripts/voc/000004.jpg')
  pvalib._detect_net(img.tobytes(), img.shape[1], img.shape[0])
  pvalib.free_net(net)

  net.contents.param_path = '../data/pvanet/pvanet_light'
  net.contents.input_scale = 600
  load_pva33(generate=True)
  pvalib.setup_frcnn(net, 'convf', 'convf', 256, 1, 1, 1, 512, 128, 12000, 300)
  pvalib.get_tensor_by_name(net, 'conv1').contents.data_type = 1
  pvalib.get_tensor_by_name(net, 'conv3').contents.data_type = 1
  pvalib.shape_net(net)
  pvalib.malloc_net(net)
  pvalib._detect_net(img.tobytes(), img.shape[1], img.shape[0])
  pvalib.free_net(net)
