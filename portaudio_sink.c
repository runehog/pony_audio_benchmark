#include <assert.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <portaudio.h>
#include <pthread.h>

#if __APPLE__
#include <dispatch/dispatch.h>
#endif

#define FAKE_AUDIO 0
#define USE_PRODUCE_THREAD 1
#define DETECT_UNDERRUNS 0

typedef struct _buffer {
  uint8_t ready;
  float* buf;
} _buffer;

static PaStream* g_stream = NULL;
static unsigned long g_frames_per_buffer = 0;
static _buffer* g_buffers;
static size_t g_buffer_count = 0;
static size_t g_next_buffer = 0;

static pthread_t g_produce_thread;
#if __APPLE__
static dispatch_semaphore_t g_produce_sem;
#else
static sem_t g_produce_sem;
#endif
static double g_produce_timestamp;
static uint32_t g_produce_underruns;

// the ponyland callbacks
typedef void (*pony_output_add_buffer_cb)(void* pony_object, float* io_buffer, uint8_t* io_ready);
typedef void (*pony_output_preroll_cb)(void* pony_object);
typedef void (*pony_output_produce_cb)(void* pony_object, double timestamp);

static pony_output_add_buffer_cb g_add_buffer_cb = NULL;
static pony_output_preroll_cb g_preroll_cb = NULL;
static pony_output_produce_cb g_produce_cb = NULL;
static void* g_pony_object;

// registers this thread with the pony runtime.
extern void pony_register_thread();

void init_buffers(unsigned long buffer_count) {
  int i;
  g_buffers = (_buffer*)malloc(sizeof(_buffer) * buffer_count);
  for (i = 0; i < buffer_count; ++i) {
    g_buffers[i].ready = 0;
    g_buffers[i].buf = (float*) malloc(sizeof(float) * g_frames_per_buffer);
  }
  g_buffer_count = buffer_count;
}

void preroll() {
  printf("preroll: add buffer %p preroll %p produce %p\n",
      g_add_buffer_cb,
      g_preroll_cb,
      g_produce_cb);
  // Send buffers.
  int i;
  for (i = 0; i < g_buffer_count; ++i) {
    (*g_add_buffer_cb)(g_pony_object, g_buffers[i].buf, &g_buffers[i].ready);
  }

  // Signal start of preroll phase.
  (*g_preroll_cb)(g_pony_object);

  // Fill.
  for (i = 0; i < g_buffer_count; ++i) {
    (*g_produce_cb)(g_pony_object, 0.);
  }
}

void* produce_thread(void* unused) {
  pony_register_thread();
  uint32_t underruns = g_produce_underruns;
  while (1) {
#if __APPLE__
    int wait_result = dispatch_semaphore_wait(
      g_produce_sem, DISPATCH_TIME_FOREVER);
#else
    int wait_result = sem_wait(&g_produce_sem);
#endif
    if (wait_result != 0) {
      printf("Producer thread done\n");
      return NULL;
    }
    if (g_produce_underruns > underruns) {
      printf("%d underruns\n", g_produce_underruns - underruns);
      underruns = g_produce_underruns;
    }
    (*g_produce_cb)(g_pony_object, g_produce_timestamp);
  }
  return NULL;
}

void init_produce_thread() {
  int result;
  g_produce_timestamp = 0;
#if __APPLE__
  g_produce_sem = dispatch_semaphore_create(0);
#else
  result = sem_init(&g_produce_sem, 0, 0);
  assert(result == 0);
#endif
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  result = pthread_create(&g_produce_thread, &attr, &produce_thread, NULL);
  assert(result == 0);
}

#if FAKE_AUDIO

static int g_fakeaudio_run = 1;
static pthread_t g_fakeaudio_thread;

void* fakeaudio_thread(void* unused) {
  int count = 0;
  while (g_fakeaudio_run) {
    // wait 128/44100 microseconds.
    usleep(2902);
    //usleep(1000000);
    // notify the producer.
    if (!(++count & 0x3f)) {
      puts(".");
    }
#if USE_PRODUCE_THREAD
#if __APPLE__
    dispatch_semaphore_signal(g_produce_sem);
#else
    sem_post(&g_produce_sem);
#endif
#else
    (*g_produce_cb)(g_pony_object, g_produce_timestamp);
#endif
    // +++ update timestamp
  }
}

void init_fakeaudio_thread() {
  int result;
  g_fakeaudio_run = 1;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  result = pthread_create(&g_fakeaudio_thread, &attr, &fakeaudio_thread, NULL);
  assert(result == 0);
}

#endif // FAKE_AUDIO

// the portaudio callback
int output_stream_cb(const void* input,
                     void* output,
                     unsigned long frames_per_buffer,
                     const PaStreamCallbackTimeInfo* time_info,
                     PaStreamCallbackFlags status_flags,
                     void* user) {
#if !USE_PRODUCE_THREAD
  static int first = 1;
  if (first) {
    first = 0;
    pony_register_thread();
  }
#endif
  assert(frames_per_buffer == g_frames_per_buffer);

#if DETECT_UNDERRUNS
  if (g_buffers[g_next_buffer].ready) {
#endif
    memcpy(output, g_buffers[g_next_buffer].buf, frames_per_buffer * sizeof(float));
    g_buffers[g_next_buffer].ready = 0;
    g_produce_timestamp = time_info->outputBufferDacTime;
#if USE_PRODUCE_THREAD
#if __APPLE__
    dispatch_semaphore_signal(g_produce_sem);
#else
    sem_post(&g_produce_sem);
#endif
#else
    (*g_produce_cb)(g_pony_object, g_produce_timestamp);
#endif
    if (++g_next_buffer == g_buffer_count) {
      g_next_buffer = 0;
    }
#if DETECT_UNDERRUNS
  } else {
    // underrun!
    g_produce_underruns++;
  }
#endif
  return paContinue;
}

int init_output_stream(unsigned long frames_per_buffer,
                       unsigned long buffer_count,
                       pony_output_add_buffer_cb add_buffer_cb,
                       pony_output_preroll_cb preroll_cb,
                       pony_output_produce_cb produce_cb,
                       void* pony_object) {
  printf("init: cbs: add buffer %p preroll %p produce %p\n",
    add_buffer_cb,
    preroll_cb,
    produce_cb);
  if (NULL != g_stream) {
    return paDeviceUnavailable;
  }

#if FAKE_AUDIO
#else
  PaError result = Pa_Initialize();
  if (paNoError != result) {
    return result;
  }

  PaDeviceIndex device_index = Pa_GetDefaultOutputDevice();
  int device_count = Pa_GetDeviceCount();
  int i;
  for (i = 0; i < device_count; ++i) {
    printf("dev %d: %s\n", i, Pa_GetDeviceInfo(i)->name);
    if (!strcmp("pulse", Pa_GetDeviceInfo(i)->name)) {
      device_index = i;
      break;
    }
  }
  if (device_index < 0) {
    return device_index;
  }
  const PaDeviceInfo* device_info = Pa_GetDeviceInfo(device_index);

  PaStream* stream;
#if 0
  result = Pa_OpenDefaultStream(&stream,
                                0, // no inputs
                                1, // 1 output
                                paFloat32,
                                44100,
                                frames_per_buffer,
                                &output_stream_cb,
                                pony_object);
#else
  PaStreamParameters output_params;
  output_params.channelCount = 1;
  output_params.device = device_index;
  output_params.hostApiSpecificStreamInfo = NULL;
  output_params.sampleFormat = paFloat32;
  output_params.suggestedLatency = device_info->defaultLowOutputLatency;
  output_params.hostApiSpecificStreamInfo = NULL;

  result = Pa_IsFormatSupported(NULL, &output_params, 44100.0);
  if (result != 0) {
    printf("format not supported!\n");
    return result;
  }
  const PaHostApiInfo* api_info = Pa_GetHostApiInfo(device_info->hostApi);
  printf("using device '%s', API '%s'\n", device_info->name, api_info->name);
  printf("latency: %lf\n", device_info->defaultLowOutputLatency);
  result = Pa_OpenStream(
    &stream,
    NULL,
    &output_params,
    44100.0,
    frames_per_buffer,
    paNoFlag,
    &output_stream_cb,
    pony_object);
#endif

  if (paNoError != result) {
    return result;
  }

  g_stream = stream;
#endif // FAKE_AUDIO

  g_frames_per_buffer = frames_per_buffer;
  g_pony_object = pony_object;
  g_add_buffer_cb = add_buffer_cb;
  g_preroll_cb = preroll_cb;
  g_produce_cb = produce_cb;
  init_buffers(buffer_count);
  preroll();

  return paNoError;
}

int start_output_stream() {
#if USE_PRODUCE_THREAD
  init_produce_thread();
#endif
#if FAKE_AUDIO
  init_fakeaudio_thread();
  return 0;
#else
  PaError result = Pa_StartStream(g_stream);
  return result;
#endif
}

int stop_output_stream() {
  printf("stop_output_stream() IN\n");
#if FAKE_AUDIO
  g_fakeaudio_run = 0;
  return 0;
#else
  PaError result = Pa_StopStream(g_stream);
  return result;
#endif
}
