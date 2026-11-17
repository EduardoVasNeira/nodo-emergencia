"""Piezas compartidas: el modelo que convierte texto en vectores (multilingual-e5-small, ONNX int8)."""
import os

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

MODELO = os.environ.get("MODELO_DIR", "/modelo")
INDICE = os.environ.get("INDICE_DIR", "/indice")


class Vectorizador:
    """Texto -> vector normalizado de 384 dimensiones. e5 pide prefijos 'query: ' y 'passage: '."""

    def __init__(self, hilos=2, largo_max=256):
        so = ort.SessionOptions()
        so.intra_op_num_threads = hilos
        so.inter_op_num_threads = 1
        self.sesion = ort.InferenceSession(os.path.join(MODELO, "model.onnx"), so,
                                           providers=["CPUExecutionProvider"])
        self.entradas = {i.name for i in self.sesion.get_inputs()}
        self.tok = Tokenizer.from_file(os.path.join(MODELO, "tokenizer.json"))
        self.tok.enable_truncation(max_length=largo_max)
        self.tok.enable_padding(pad_id=self.tok.token_to_id("<pad>") or 1, pad_token="<pad>")

    def __call__(self, textos):
        enc = self.tok.encode_batch(list(textos))
        ids = np.array([e.ids for e in enc], dtype=np.int64)
        mascara = np.array([e.attention_mask for e in enc], dtype=np.int64)
        datos = {"input_ids": ids, "attention_mask": mascara}
        if "token_type_ids" in self.entradas:
            datos["token_type_ids"] = np.zeros_like(ids)
        salida = self.sesion.run(None, datos)[0]
        m = mascara[..., None].astype(np.float32)
        v = (salida * m).sum(1) / np.maximum(m.sum(1), 1e-9)
        v /= np.maximum(np.linalg.norm(v, axis=1, keepdims=True), 1e-9)
        return v.astype(np.float32)
