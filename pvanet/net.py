import mxnet as mx
import caffe

def conv(prev_top, num_layer, num_filter):
    conv1 = mx.symbol.Convolution(name='conv{:d}_1'.format(num_layer), data=prev_top,
                                  kernel=(3, 3), stride=(2, 2), pad=(1, 1), num_filter=num_filter)
    relu1 = mx.symbol.Activation(name='relu{:d}_1'.format(num_layer), data=conv1, act_type='relu')
    conv2 = mx.symbol.Convolution(name='conv{:d}_2'.format(num_layer), data=relu1,
                                  kernel=(3, 3), stride=(1, 1), pad=(1, 1), num_filter=num_filter*2)
    relu2 = mx.symbol.Activation(name='relu{:d}_1'.format(num_layer), data=conv2, act_type='relu')
    return relu2

def fc(prev_top, num_layer, num_hidden, dropout=True):
    fc = mx.symbol.FullyConnected(name='fc{:d}'.format(num_layer), data=prev_top, num_hidden=num_hidden)
    relu = mx.symbol.Activation(name='relu{:d}'.format(num_layer), data=fc, act_type='relu')
    drop = mx.symbol.Dropout(name='drop{:d}'.format(num_layer), data=relu, p=0.5)
    return drop

def get_symbol(num_classes=21):
    layer = mx.symbol.Variable(name='data')
    layer = conv(layer, 1, 16)
    layer = conv(layer, 2, 32)
    layer = conv(layer, 3, 64); layer3 = layer
    layer = conv(layer, 4, 128); layer4 = layer
    layer = conv(layer, 5, 256); layer5 = layer

    layer5_slice = mx.symbol.SliceChannel(data=layer5, num_outputs=512, name='conv5_slice')
    deconv = [mx.symbol.Deconvolution(name='upsample_{:d}'.format(i), data=layer5_slice[i],
                                      kernel=(4, 4), stride=(2, 2), pad=(1, 1), num_filter=1,
                                      no_bias=True) for i in range(512)]
    up = mx.symbol.Concat(*deconv, name='concat')
    down = mx.symbol.Pooling(name='downsample', data=layer3,
                             kernel=(3, 3), stride=(2, 2), pad=(0, 0), pool_type='max')
    layer = mx.symbol.Concat(*[down, layer4, up], name='concat')
    layer = mx.symbol.Convolution(name='convf', data=layer,
                                  kernel=(1, 1), stride=(1, 1), pad=(0, 0), num_filter=512)
    layer = mx.symbol.Activation(name='reluf', data=layer, act_type='relu')
    layer = mx.symbol.Pooling(name='poolf', data=layer,
                              kernel=(2, 2), stride=(2, 2), pad=(0, 0), pool_type='max')

    layer = mx.symbol.Flatten(data=layer)
    layer = fc(layer, 6, 4096)
    layer = fc(layer, 7, 4096)

    layer = mx.symbol.FullyConnected(name='cls_score', data=layer, num_hidden=num_classes)
    layer = mx.symbol.SoftmaxOutput(name='cls_prob', data=layer)
    return layer

def load_model(caffeproto, caffemodel, num_classes=21):
    caffe_net = caffe.Net(caffeproto, caffemodel, caffe.TEST)
    symbol = get_symbol(num_classes)
    arg_shapes, out_shapes, aux_shapes = symbol.infer_shape(**{'data': (1, 3, 192, 192)})
    arg_shape_dic = { name: shape for name, shape in zip(symbol.list_arguments(), arg_shapes) }

    arg_params = {}
    is_first_conv = True
    for layer_name in caffe_net.params.keys():
        if layer_name.startswith('data'):
            continue

        print 'Loading {} parameters'.format(layer_name)
        
        wmat = caffe_net.params[layer_name][0].data
        if is_first_conv and layer_name.startswith('conv'):
            print 'Swapping BGR -> RGB order'
            wmat[:, [0, 2], :, :] = wmat[:, [2, 0], :, :]
            is_first_conv = False

        if layer_name.startswith('upsample'):
            for i in range(wmat.shape[0]):
                weight_name = layer_name + '_{:d}_weight'.format(i)
                if arg_shape_dic.has_key(weight_name):
                    wmat_i = wmat[i].reshape((1, wmat.shape[1], wmat.shape[2], wmat.shape[3]))
                    print 'Original {}: {}'.format(weight_name, wmat_i.shape)
                    print 'Target {}: {}'.format(weight_name, arg_shape_dic[weight_name])
                    arg_params[weight_name] = mx.nd.zeros(arg_shape_dic[weight_name])
                    arg_params[weight_name][:] = wmat_i

        weight_name = layer_name + '_weight'
        if arg_shape_dic.has_key(weight_name):
            print 'Original {}: {}'.format(weight_name, wmat.shape)
            print 'Target {}: {}'.format(weight_name, arg_shape_dic[weight_name])
            arg_params[weight_name] = mx.nd.zeros(arg_shape_dic[weight_name])
            arg_params[weight_name][:] = wmat

        if len(caffe_net.params[layer_name]) == 1:
            continue

        bias = caffe_net.params[layer_name][1].data
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

