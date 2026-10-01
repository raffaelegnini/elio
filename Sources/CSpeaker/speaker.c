#include "speaker.h"
#include <onnxruntime_c_api.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/// Releases a non-NULL status; true if the call failed.
#define ORT_FAILED(api, expr) ({ OrtStatus *st__ = (expr); if (st__) (api)->ReleaseStatus(st__); st__ != NULL; })

typedef struct {
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtMemoryInfo *memory;
    char *input_name;
    char *output_name;
} Speaker;

static int failed(const OrtApi *api, OrtStatus *status, char *error, int error_len) {
    if (!status) return 0;
    if (error && error_len > 0) snprintf(error, error_len, "%s", api->GetErrorMessage(status));
    api->ReleaseStatus(status);
    return 1;
}

void *spk_create(const char *model_path, char *error, int error_len) {
    const OrtApi *api = OrtGetApiBase()->GetApi(ORT_API_VERSION);
    if (!api) { snprintf(error, error_len, "ONNX Runtime API unavailable"); return NULL; }
    Speaker *s = calloc(1, sizeof(Speaker));
    s->api = api;
    OrtSessionOptions *options = NULL;
    OrtAllocator *allocator = NULL;
    if (failed(api, api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "elio-speaker", &s->env), error, error_len)) goto fail;
    if (failed(api, api->CreateSessionOptions(&options), error, error_len)) goto fail;
    ORT_FAILED(api, api->SetIntraOpNumThreads(options, 2));
    if (failed(api, api->CreateSession(s->env, model_path, options, &s->session), error, error_len)) goto fail;
    api->ReleaseSessionOptions(options); options = NULL;
    if (failed(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &s->memory), error, error_len)) goto fail;
    if (failed(api, api->GetAllocatorWithDefaultOptions(&allocator), error, error_len)) goto fail;
    char *name = NULL;
    if (failed(api, api->SessionGetInputName(s->session, 0, allocator, &name), error, error_len)) goto fail;
    s->input_name = strdup(name); ORT_FAILED(api, api->AllocatorFree(allocator, name));
    if (failed(api, api->SessionGetOutputName(s->session, 0, allocator, &name), error, error_len)) goto fail;
    s->output_name = strdup(name); ORT_FAILED(api, api->AllocatorFree(allocator, name));
    return s;
fail:
    if (options) api->ReleaseSessionOptions(options);
    spk_free(s);
    return NULL;
}

int spk_embed(void *handle, const float *feats, int frames, int dim, float *out, int out_len) {
    Speaker *s = handle;
    if (!s || frames <= 0) return -1;
    const OrtApi *api = s->api;
    int64_t shape[3] = {1, frames, dim};
    OrtValue *input = NULL, *output = NULL;
    int result = -1;
    if (ORT_FAILED(api, api->CreateTensorWithDataAsOrtValue(s->memory, (void *)feats, sizeof(float) * frames * dim, shape, 3,
                                                            ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input))) goto done;
    const char *inputs[1] = {s->input_name};
    const char *outputs[1] = {s->output_name};
    if (ORT_FAILED(api, api->Run(s->session, NULL, inputs, (const OrtValue *const *)&input, 1, outputs, 1, &output))) goto done;
    float *data = NULL;
    if (ORT_FAILED(api, api->GetTensorMutableData(output, (void **)&data))) goto done;
    OrtTensorTypeAndShapeInfo *info = NULL;
    size_t count = 0;
    if (ORT_FAILED(api, api->GetTensorTypeAndShape(output, &info))) goto done;
    ORT_FAILED(api, api->GetTensorShapeElementCount(info, &count));
    api->ReleaseTensorTypeAndShapeInfo(info);
    int n = (int)count < out_len ? (int)count : out_len;
    memcpy(out, data, sizeof(float) * n);
    result = n;
done:
    if (input) api->ReleaseValue(input);
    if (output) api->ReleaseValue(output);
    return result;
}

void spk_free(void *handle) {
    Speaker *s = handle;
    if (!s) return;
    if (s->session) s->api->ReleaseSession(s->session);
    if (s->memory) s->api->ReleaseMemoryInfo(s->memory);
    if (s->env) s->api->ReleaseEnv(s->env);
    free(s->input_name);
    free(s->output_name);
    free(s);
}
