import mxnet as mx
import caffe

def conv(prev_top, num_layer, num_filter):
    conv1 = mx.symbol.Convolution(name='conv{:d}_1'.format(num_layer), data=prev_top,
                                  kernel=(3, 3), stride=(2, 2), pad=(1, 1), num_filter=num_filter)
    relu1 = mx.symbol.Activation(name='relu{:d}_1'.format(num_layer), data=conv1, act_type="relu")
    conv2 = mx.symbol.Convolution(name='conv{:d}_2'.format(num_layer), data=relu1,
                                  kernel=(3, 3), stride=(1, 1), pad=(1, 1), num_filter=num_filter*2)
    relu2 = mx.symbol.Activation(name='relu{:d}_1'.format(num_layer), data=conv2, act_type="relu")
    return relu2

def get_symbol(num_classes = 1000):
    layer = mx.symbol.Variable(name='data')
    layer = conv(layer, 1, 16)
    layer = conv(layer, 2, 32)
    layer = conv(layer, 3, 64)
    layer = conv(layer, 4, 128)
    layer = conv(layer, 5, 256)
    return layer

def load_model(caffeproto, caffemodel):
    caffe_net = caffe.Net(caffeproto, caffemodel, caffe.TEST)
    symbol = get_symbol()
    arg_shapes, out_shapes, aux_shapes = symbol.infer_shape(**{'data': (1, 3, 640, 640)})
    arg_shape_dic = { name: shape for name, shape in zip(symbol.list_arguments(), arg_shapes) }

    arg_params = {}
    is_first_conv = True
    for layer_name in caffe_net.params.keys():
        if layer_name.startswith('data') or layer_name.startswith('fc'):
            continue

        print 'Loading {} parameters'.format(layer_name)
        
        wmat = caffe_net.params[layer_name][0].data
        if is_first_conv and layer_name.startswith('conv'):
            print 'Swapping BGR -> RGB order'
            wmat[:, [0, 2], :, :] = wmat[:, [2, 0], :, :]
            is_first_conv = False
        #wmat = wmat.reshape((wmat.shape[0], -1))
        weight_name = layer_name + '_weight'
        if arg_shape_dic.has_key(weight_name):
            print 'Original {}: {}'.format(weight_name, wmat.shape)
            print 'Target {}: {}'.format(weight_name, arg_shape_dic[weight_name])
            arg_params[weight_name] = mx.nd.zeros(wmat.shape)
            arg_params[weight_name][:] = wmat

        bias = caffe_net.params[layer_name][1].data
        #bias.reshape((bias.shape[0], 1))
        bias_name = layer_name + '_bias'
        if arg_shape_dic.has_key(bias_name):
            print 'Original {}: {}'.format(bias_name, bias.shape)
            print 'Target {}: {}'.format(bias_name, arg_shape_dic[bias_name])
            arg_params[bias_name] = mx.nd.zeros(bias.shape)
            arg_params[bias_name][:] = bias

    model = mx.model.FeedForward(ctx=mx.cpu(), symbol=symbol, arg_params=arg_params,
                                 aux_params={}, num_epoch=1,
                                 learning_rate=0.01, momentum=0.9, wd=0.0001)
    model.save(caffemodel + '.mx')

