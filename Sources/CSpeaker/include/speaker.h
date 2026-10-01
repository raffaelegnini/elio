#ifndef ELIO_SPEAKER_H
#define ELIO_SPEAKER_H

// Speaker embedding with ONNX Runtime (WeSpeaker ResNet34: fbank [T, 80] -> embedding).
// Tiny C surface so Swift doesn't have to drive the ONNX Runtime C API directly.

void *spk_create(const char *model_path, char *error, int error_len);
/// Returns the embedding length written to `out` (<= out_len), or -1 on error.
int spk_embed(void *handle, const float *feats, int frames, int dim, float *out, int out_len);
void spk_free(void *handle);

#endif
