from struct import pack, unpack
import numpy as np
import matplotlib.pyplot as plt
import dl

#param = [(-3, 32), (-3, 16), (-3, 8), (2, 4), (4.5, 2), (3.5, 1), (3.9, .5), (4.01, .25), (4, .125)]
param = [(19, 10), (14, 4), (7, 2), (2, 2)]

def load_image(filename):
  import scipy.ndimage
  import scipy.misc
  img = scipy.ndimage.imread(filename)

  #if len(img.shape) == 3:
  #  img = img[:,:,:3].swapaxes(0, 2).swapaxes(1, 2)[::-1]
  #elif len(img.shape) == 2:
  #  img = np.tile(img, (3, 1, 1))
  #else:
  #  raise Exception
  #print img.shape

  scale = np.float32(600.0 / min(img.shape[:1]))
  if round(scale * max(img.shape[:1])) > 1000:
    scale = np.float32(1000.0 / max(img.shape[:1]))
  scale_h = np.float32(int(img.shape[0] * scale / 32) * 32.0 / img.shape[0])
  scale_w = np.float32(int(img.shape[1] * scale / 32) * 32.0 / img.shape[1])
  print [scale_h, scale_w]

  im_h = int(round(img.shape[0] * scale_h))
  im_w = int(round(img.shape[1] * scale_w))
  img_scaled = scipy.misc.imresize(img, (im_h, im_w))
  return img_scaled, np.array([im_h, im_w, scale_w, scale_h], np.float32).reshape(1, 4)

def inceptions():
  #proto = '../new-faster-rcnn/pva_inception2_3_coco.pt'
  #model = '../new-faster-rcnn/output/faster_rcnn_once_25anc_plus/pvtdb_pengo_80_pva/pva_inception2_3_once_iter_330000.caffemodel'
  #proto = '../new-faster-rcnn/pva_inception2_coco.pt'
  #model = '../new-faster-rcnn/output/faster_rcnn_once_25anc_plus/pvtdb_pengo_80_pva/pva_inception2_2_once_iter_4720000.caffemodel'
  #proto = '../new-faster-rcnn/pva7.1.1_coco.pt'
  #model = '../new-faster-rcnn/pva7.1.1_coco_once_iter_880000.caffemodel'
  #proto = '../new-faster-rcnn/pva_inception2_4.pt'
  #model = '../new-faster-rcnn/output/faster_rcnn_once_25anc_plus/pvtdb_pengo3_24_pva/pva_inception2_4_once_iter_1750000.caffemodel'
  #proto = '../new-faster-rcnn/models/pva_inception64_4/pva_inception64_4_test.pt'
  #model = '../new-faster-rcnn/models/pva_inception64_4/pva_inception64_4_train_iter_1074505.caffemodel'
  #proto = '../new-faster-rcnn/models/pva_inception64_4/faster_rcnn_once/faster_rcnn_train_convert.pt'
  #model = '../new-faster-rcnn/output/faster_rcnn_once_25anc_plus/pvtdb_pengo2_84_pva/Round3/pva_inception64_4_once_iter_900000.caffemodel'
  #proto_src = 'faster_rcnn_train_test.pt'
  #proto_dest = 'faster_rcnn_train_test_comb.pt'
  #model = 'pva9.0.0_fixed.caffemodel'

def inception(x):
  y = {}
  for (rf, num) in x.items():
    if y.has_key(rf):
      y[rf] += num * 2
    else:
      y[rf] = num * 2
    if y.has_key(rf + 2):
      y[rf + 2] += num
    else:
      y[rf + 2] = num
    if y.has_key(rf + 4):
      y[rf + 4] += num
    else:
      y[rf + 4] = num
  return y

def test_bn(net):
  a = net.blobs['inc3a/conv5_2'].data.copy()
  b = net.blobs['inc3a/conv5_2/bn'].data.copy()
  n = net.params['inc3a/conv5_2/bn'][2].data[0]
  m = net.params['inc3a/conv5_2/bn'][0].data.copy()
  v = net.params['inc3a/conv5_2/bn'][1].data.copy()
  m /= n
  v = 1 / np.sqrt(v / n)
  for i in range(m.shape[0]):
    a[:,i,:,:] = (a[:,i,:,:] - m[i]) * v[i]

def test_scale(net):
  a = net.blobs['inc3a/conv5_2/bn'].data.copy()
  b = net.blobs['inc3a/conv5_2/scale'].data.copy()
  w = net.params['inc3a/conv5_2/scale'][0].data.copy()
  c = net.params['inc3a/conv5_2/scale'][1].data.copy()
  for i in range(w.shape[0]):
    a[:,i,:,:] = w[i] * a[:,i,:,:] + c[i]

def test_bn_scale(net):
  a = net.blobs['inc3a/conv5_2'].data.copy()
  b = net.blobs['inc3a/conv5_2/scale'].data.copy()
  n = net.params['inc3a/conv5_2/bn'][2].data[0]
  m = net.params['inc3a/conv5_2/bn'][0].data.copy()
  v = net.params['inc3a/conv5_2/bn'][1].data.copy()
  w = net.params['inc3a/conv5_2/scale'][0].data.copy()
  c = net.params['inc3a/conv5_2/scale'][1].data.copy()
  alpha = w / np.sqrt(v / n)
  beta = c - (m / n) * alpha
  for i in range(m.shape[0]):
    a[:,i,:,:] = a[:,i,:,:] * alpha[i] + beta[i]
    #a[:,i,:,:] = (a[:,i,:,:] - m[i]) * v[i] * w[i] + c[i]

def combine_conv_bn_scale(net, keyset=None):
  def copy_double(data):
    return np.array(data, copy=True, dtype=np.double)
  if keyset is None:
    keyset = [key[:-3] for key in net.params.keys() if key.endswith('/bn')]

  for key in keyset:
    weight = copy_double(net.params[key][0].data)
    bias = copy_double(net.params[key][1].data)
    num_bn_samples = copy_double(net.params[key + '/bn'][2].data)
    bn_mean = copy_double(net.params[key + '/bn'][0].data)
    bn_variance = copy_double(net.params[key + '/bn'][1].data)
    scale_weight = copy_double(net.params[key + '/scale'][0].data)
    scale_bias = copy_double(net.params[key + '/scale'][1].data)

    if num_bn_samples[0] == 0:
      num_bn_samples[0] = 1
    alpha = scale_weight / np.sqrt(bn_variance / num_bn_samples[0] + np.finfo(np.double).eps)
    net.params[key][1].data[:] = bias * alpha + (scale_bias - (bn_mean / num_bn_samples[0]) * alpha)
    for i in range(len(alpha)):
      net.params[key][0].data[i] = weight[i] * alpha[i]

    net.params[key + '/bn'][0].data[:] = 0
    net.params[key + '/bn'][1].data[:] = 1
    net.params[key + '/bn'][2].data[:] = 1
    net.params[key + '/scale'][0].data[:] = 1
    net.params[key + '/scale'][1].data[:] = 0

def rpn_score_bbox_corr(net):
  score_names = ['rpn_cls_score1', 'rpn_cls_score3', 'rpn_cls_score5']
  bbox_names = ['rpn_bbox_pred1', 'rpn_bbox_pred3', 'rpn_bbox_pred5']
  anchor_nums = [9, 9, 9]
  for (score_name, bbox_name, anchor_num) in zip(score_names, bbox_names, anchor_nums):
    score = net.params[score_name][0].data.reshape(2, anchor_num, -1)
    bbox = net.params[bbox_name][0].data.reshape(anchor_num, 4, -1).swapaxes(0, 1)
    for s in score:
      for b in bbox:
        for i in range(anchor_num):
          v1 = np.abs(s[i]) / np.sqrt(np.sum(s[i] ** 2))
          v2 = np.abs(b[i]) / np.sqrt(np.sum(b[i] ** 2))
          print (np.sqrt((v1 * v2).sum()), np.sqrt((v1 * v1).sum()), np.sqrt((v2 * v2).sum()))

def graph():
  x = np.array(range(-4000, 4000, 5)) / 100.0
  y = nested_normal(x)
  plt.plot(x, y)
  plt.xlabel('x')
  plt.ylabel('f(x)')
  plt.show()
  y = grad_nested_normal(x)
  plt.plot(x, y)
  plt.xlabel('x')
  plt.ylabel("grad f(x)")
  plt.show()

def normal(x, mu, var):
  #return (1.0 / np.sqrt(2 * np.pi * var)) * np.exp((-0.5 / var) * (x - mu) ** 2)
  x = np.array(x)
  diff = np.abs(x) - mu
  val = np.zeros(x.shape)
  val[diff > 0] = (1.0 / np.sqrt(2 * np.pi * var)) * np.exp((-0.5 / var) * diff[diff > 0] ** 2)
  val[diff <= 0] = (1.0 / np.sqrt(2 * np.pi * var)) * (1.0 - 0.1 * diff[diff <= 0] / mu)
  return val

def grad_normal(x, mu, var):
  #return (1.0 / var) * normal(x, mu, var) * (mu - np.array(x))
  x = np.array(x)
  diff = np.abs(x) - mu
  val = np.zeros(x.shape)
  r = (diff >= 0) * (x >= 0)
  val[r] = (1.0 / var) * normal(x[r], mu, var) * (mu - x[r])
  r = (diff >= 0) * (x < 0)
  val[r] = (1.0 / var) * normal(x[r], mu, var) * (-mu - x[r])
  r = (diff < 0) * (x >= 0)
  val[r] = -(1.0 / np.sqrt(2 * np.pi * var)) * 0.1 / mu
  r = (diff < 0) * (x < 0)
  val[r] = +(1.0 / np.sqrt(2 * np.pi * var)) * 0.1 / mu
  return val

def nested_normal(x):
  return -np.array([normal(x, m, v) for (m, v) in param]).sum(axis=0)

def grad_nested_normal(x):
  #return -np.array([grad_normal(x, m, v) + np.random.normal(0, 0.005*np.sqrt(v), x.shape) for (m, v) in param]).sum(axis=0)
  return -np.array([grad_normal(x, m, v) for (m, v) in param]).sum(axis=0)

def track(x0):
  x = np.zeros((1000,))
  fx = np.zeros(x.shape)
  step = np.zeros(x.shape)
  x[0] = x0
  step[:] = 10
#  step[:100] = 0.23
#  step[100:200] = 0.22
#  step[200:300] = 0.21
#  step[300:400] = 0.20
#  step[400:500] = 0.19
#  step[500:600] = 0.18
#  step[600:700] = 0.17
#  step[700:800] = 0.16
#  step[800:900] = 0.15
#  step[900:1000] = 0.14
  for i in range(x.shape[0]):
    fx[i] = nested_normal(x[i])
    dx = grad_nested_normal(x[i])
    print "Iter {:4d}: x = {:.2f}, f(x) = {:.6f}, f'(x) = {:.6f}".format(i, x[i], fx[i], dx)
    if i < x.shape[0] - 1:
      x[i+1] = x[i] - step[i] * dx
  plt.plot(fx.reshape(200,5).mean(axis=1))
  plt.show()

def layer_img(img, layer):
  scale_h = img.shape[0] / layer.shape[1]
  scale_w = img.shape[1] / layer.shape[2]
  patch_height = 91
  patch_width = 91
  layer_flat = layer.reshape((layer.shape[0], -1))
  mean_patches = np.zeros((layer.shape[0], patch_height, patch_width, 3), dtype=np.uint8)
  mean_patch = np.zeros((patch_height, patch_width, 3), dtype=np.double)
  weight = np.zeros((1,), dtype=np.double)
  for ch in range(layer.shape[0]):
    weight[0] = 0
    for i, val in enumerate(layer_flat[ch]):
      if val > 0:
            x_ctr = (i % layer.shape[2]) * scale_w
            y_ctr = (i / layer.shape[2]) * scale_h
            x1 = min(max(0, x_ctr), img.shape[1])
            y1 = min(max(0, y_ctr), img.shape[0])
            x2 = min(max(0, x_ctr + patch_width), img.shape[1])
            y2 = min(max(0, y_ctr + patch_height), img.shape[0])
            w = x2 - x1
            h = y2 - y1
            mean_patch[:h, :w, :] += val * img[y1:y2, x1:x2, :]
            weight[0] += val
    mean_patches[ch] = mean_patch / weight[0]
  return mean_patches

def layer_topk(img, layer, ch, num_top=64):
  scale_h = img.shape[0] / layer.shape[1]
  scale_w = img.shape[1] / layer.shape[2]
  patch_height = 91
  patch_width = 91
  layer_flat = layer.reshape((layer.shape[0], -1))
  val = np.ceil(np.sqrt(num_top))
  topk = np.argsort(layer_flat[ch])[::-1][:num_top]
  scores = layer_flat[ch, topk]
  for i, idx in enumerate(topk):
      x_ctr = (idx % layer.shape[2]) * scale_w
      y_ctr = (idx / layer.shape[2]) * scale_h
      x1 = min(max(0, x_ctr), img.shape[1])
      y1 = min(max(0, y_ctr), img.shape[0])
      x2 = min(max(0, x_ctr + patch_width), img.shape[1])
      y2 = min(max(0, y_ctr + patch_height), img.shape[0])
      print '{:d}: ({:f},{:f}), ({:f},{:f}), score = {:f}'.format(idx, x1, y1, x2, y2, scores[i])
      w = x2 - x1
      h = y2 - y1
      plt.subplot(val, val, i + 1)
      img_sub = np.zeros((patch_height, patch_width, 3), dtype=np.uint8)
      img_sub[:h, :w, :] = img[y1:y2, x1:x2, :]
      if h < patch_height:
        img_sub[h:, :, :] = 0
      if w < patch_width:
        img_sub[:, w:, :] = 0
      fig = plt.imshow(img_sub)
      plt.axis=('off')
      fig.axes.get_xaxis().set_visible(False)
      fig.axes.get_yaxis().set_visible(False)
  plt.show()

def plot_imgs(imgs):
  val = np.ceil(np.sqrt(imgs.shape[0]))
  for i in range(imgs.shape[0]):
    plt.subplot(val, val, i + 1)
    fig = plt.imshow(imgs[i], interpolation='bilinear')
    plt.axis=('off')
    fig.axes.get_xaxis().set_visible(False)
    fig.axes.get_yaxis().set_visible(False)
  plt.show()

def plot_f(weight, bias, swap_bgr=False):
  val = np.ceil(np.sqrt(weight.shape[0]))
  for i in range(weight.shape[0]):
    plt.subplot(val, val, i + 1)
    w = weight[i][::-1] if swap_bgr else weight[i]
    img_shape = np.zeros((len(w.shape) + 1,))
    img_shape[1:] = w.shape
    img_shape[0] = 100000
    imgs = np.random.uniform(0, 255, img_shape)
    scores = [(w * img).sum() + bias[i] for img in imgs]
    simg_mean = np.array([0 * img if score <= 0 else score * img for score, img in zip(scores, imgs)]).mean(axis=0)
    s_mean = np.array([0 if score <= 0 else score for score in scores]).mean()
    print s_mean
    fig = plt.imshow(simg_mean / s_mean, interpolation='nearest')
    plt.axis('off')
    fig.axes.get_xaxis().set_visible(False)
    fig.axes.get_yaxis().set_visible(False)
  plt.show()

#img, im_info = dl.load_image('data/voc/2007/VOC2007/JPEGImages/000004.jpg')
#a = dl.load_data('data/temp/conv_bottom0.bin')
#b = layer_img(img, a[0])
#plot_imgs(b)
