import ctypes
from scipy.ndimage import imread
import numpy as np

lib = ctypes.CDLL('libdlcpu.so')
lib._batch_size_net.restype = ctypes.c_int
batch_size = lib._batch_size_net()

class Tensor(ctypes.Structure):
  _fields_ = [('name', ctypes.c_char * 32),
              ('num_items', ctypes.c_int),
              ('ndim', ctypes.c_int),
              ('shape', (ctypes.c_int * 5) * batch_size),
              ('start', ctypes.c_int * batch_size),
              ('data', ctypes.POINTER(ctypes.c_float)),
              ('max_data_size', ctypes.c_long)]

lib._detect_net.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int]
lib._layer_net.argtypes = [ctypes.c_int, ctypes.c_int]
lib._layer_net.restype = ctypes.POINTER(Tensor)

def init():
  lib._init_net()

def release():
  lib._release_net()

def detect(filename):
  img = imread(filename)
  if img is not None:
    lib._detect_net(img.tobytes(), img.shape[1], img.shape[0])

def top_data(layer_id, top_id = 0):
  try:
    top = lib._layer_net(layer_id, top_id).contents
    shape = np.ctypeslib.as_array(top.shape)[0, :top.ndim]
    size = np.prod(shape)
    p_data = ctypes.addressof(top.data.contents)
    data = np.ctypeslib.as_array((ctypes.c_float * size).from_address(p_data)).reshape(shape)
    return data
  except Exception:
    return None

def logging(layer_id):
  lib._print_layer(layer_id)
