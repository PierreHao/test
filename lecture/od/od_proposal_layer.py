from caffe import Layer
import numpy as np
import json

def iou(Bx, By):
  Ax = (Bx[:,2] - Bx[:,0]) * (Bx[:,3] - Bx[:,1])
  Ay = (By[:,2] - By[:,0]) * (By[:,3] - By[:,1])
  IOU = np.zeros((Bx.shape[0], By.shape[0]))
  for n, box in enumerate(By):
    AU = Ax + Ay[n]
    J1 = np.maximum(Bx[:,0], box[0])
    I1 = np.maximum(Bx[:,1], box[1])
    J2 = np.minimum(Bx[:,2], box[2])
    I2 = np.minimum(Bx[:,3], box[3])
    AI = np.maximum(I2 - I1, 0) * np.maximum(J2 - J1, 0)
    IOU[:, n] = AI / (AU - AI + 1e-6)
  return IOU

def x2Bx(pi, pj, x):
  # x = (xl, xr, xt, xb)
  # Bx = (p1_j, p1_i, p2_j, p2_i)
  Bx = np.zeros((len(x), 4), dtype=np.float32)
  Bx[:,0] = pj - x[:,0]
  Bx[:,1] = pi - x[:,2]
  Bx[:,2] = pj + x[:,1]
  Bx[:,3] = pi + x[:,3]
  return Bx

def By2y(pi, pj, By):
  y = np.zeros((len(By), 4), dtype=np.float32)
  y[:,0] = pj - By[:,0]
  y[:,1] = By[:,2] - pj
  y[:,2] = pi - By[:,1]
  y[:,3] = By[:,3] - pi
  return y

def distance(pi, pj, By):
  dist = np.zeros((pi.shape[0], By.shape[0]))
  yi = 0.5 * (By[:,1] + By[:,3])
  yj = 0.5 * (By[:,0] + By[:,2])
  yh = By[:,3] - By[:,1]
  yw = By[:,2] - By[:,0]
  for n in range(len(yi)):
    if yh[n] > yw[n]:
      dist[:,n] = np.abs(pj - yj[n]) + \
          np.abs(pi - yi[n]) * (yw[n] / yh[n])
    else:
      dist[:,n] = np.abs(pi - yi[n]) + \
          np.abs(pj - yj[n]) * (yh[n] / yw[n])
    not_in = (pj < By[n,0]) + (pj > By[n,1]) + \
             (pi < By[n,2]) + (pi > By[n,3])
    dist[not_in, n] = np.inf
  return dist

def nms(Bx, score, nms_thresh=0.7):
  idx = score.argsort()[::-1]
  Bx = Bx[idx, :]
  alive = np.ones((Bx.shape[0],), dtype=np.bool)
  for n, bx in enumerate(Bx):
    if alive[n]:
      rest = np.where(alive[n+1:])[0] + n+1
      Bx_ = Bx[rest, :].reshape(len(rest), 4)
      bx = bx.reshape(1, 4)
      IOU = iou(Bx_, bx).reshape(-1)
      alive[rest] = (IOU < nms_thresh)
  return (Bx[alive, :], score[idx[alive]])

def reconstruct(bbox_pred, obj_score, gt_boxes):
  X = np.rollaxis(bbox_pred, 1, 4)
  batch_size, h, w, _ = X.shape
  num_p = h * w
  ri = np.array(range(h)) + 0.5
  rj = np.array(range(w)) + 0.5
  pj, pi = np.meshgrid(rj, ri)
  pj = pj.reshape(-1)
  pi = pi.reshape(-1)
  X = X.reshape(batch_size, num_p, 4)
  S = obj_score.reshape(batch_size, num_p)
  for n, (x, score) in enumerate(zip(X, S)):
    Bx = x2Bx(pi, pj, x)
    candidates = score > 0.5
    if candidates.any():
      Bx = Bx[candidates]
      score = score[candidates]
      Bx, score = nms(Bx, score)
      By = gt_boxes[gt_boxes[:,0] == n, 1:5]
      IOU = iou(Bx, By)
      print IOU.max(axis=0)
  return (Bx, score)

def visualize(filename, Bx, data, scale):
  import cv2
  img = data[0].copy()
  img[0] += 103
  img[1] += 116
  img[2] += 123
  img = np.array(np.rollaxis(img, 0, 3), \
                 dtype=np.uint8).copy()
  for bx in Bx * scale:
    color = np.array(255 * np.random.rand(3,), \
                     dtype=np.int)
    cv2.rectangle(img, (bx[0], bx[1]), (bx[2], bx[3]), \
                  color, 1)
  return img

def process(X, BY):
  batch_size, h, w, _ = X.shape
  num_p = h * w
  ri = np.array(range(h)) + 0.5
  rj = np.array(range(w)) + 0.5
  pj, pi = np.meshgrid(rj, ri)
  pj = pj.reshape(-1)
  pi = pi.reshape(-1)
  X = X.reshape(batch_size, num_p, 4)
  Y = np.zeros((batch_size, num_p, 5),
               dtype=np.float32)
  obj_score = np.zeros((batch_size, num_p),
                       dtype=np.float32)
  for n, x in enumerate(X):
    By = BY[BY[:,0] == n, 1:5]
    Bx = x2Bx(pi, pj, x)
    IOU = iou(Bx, By)
    IOU_max = np.max(IOU, axis=1)
    dist = distance(pi, pj, By)
    target = np.argmin(dist, axis=1)
    Y[n, :, 0:4] = By2y(pi, pj, By[target,:])
    is_bg = (Y[n, :, 0:4] < 0).any(axis=1) + \
            (IOU_max < 0.1)
    Y[n, is_bg, 4] = 1
    obj_score[n,:] = IOU_max
  obj_score = obj_score.reshape(batch_size, h, w)
  return obj_score, Y

class ODProposalLayer(Layer):
  def setup(self, bottom, top):
    # bottom[0]: predicted box at each pixel
    #            x = (xl, xr, xt, xb)
    # bottom[1]: ground-truth boxes
    #            box = (n, p1_j, p1_i, p2_j, p2_i)
    #            n: n-th batch item
    params = json.loads(self.param_str)
    self.scale = params['scale']

  def reshape(self, bottom, top):
    # batch size
    batch_size, _, h, w = bottom[0].data.shape
    # number of pixels
    num_p = h * w
    # true objectness for each predicted box
    # (maximum IoU score with ground-truth boxes)
    top[0].reshape(batch_size, h, w)
    # target box for each predicted box
    # ignored if bg = 1 (background box)
    # y = (yl, yr, yt, yb, bg)
    top[1].reshape(batch_size, num_p, 5)

  def forward(self, bottom, top):
    # bottom[0]: (batch_size x 4 x height x width)
    # -> X: (batch_size x height x width x 4)
    X = np.rollaxis(bottom[0].data, 1, 4)
    batch_size, h, w, _ = X.shape
    num_p = h * w
    BY = bottom[1].data
    BY[:,1:5] /= self.scale
    obj_score, Y = process(X, BY)
    #top[0].reshape(batch_size, h, w)
    top[0].data[...] = obj_score
    #top[1].reshape(batch_size, num_p, 5)
    top[1].data[...] = Y

  def backward(self, top, propagate_down, bottom):
    pass

if __name__ == '__main__':
  from caffe import Net, TEST
  import cv2
  net = Net('od.pt', 'od_train_iter_58277.caffemodel', TEST)
  for count in range(100):
    net.forward()
    Bx, score = reconstruct(net.blobs['bbox'].data, net.blobs['obj_score'].data, net.blobs['gt_boxes'].data)
    img = visualize('data/pvtdb/VOC2007/JPEGImages/%06d.jpg' % count, \
              Bx, net.blobs['data'].data, 32)
    cv2.imshow('%06d.jpg' % count, img)
    key = cv2.waitKey(0)
    cv2.destroyAllWindows()
    if key == 27:
      break
