use "collections"
use "random"
use "time"
use "lib:portaudio_sink"
use "lib:portaudio"

// External sample format: 32-bit float.
type OutBuffer is Array[F32]

// Internal sample format: 64-bit float.
type Buffer is Array[F64]

primitive Clipper
  fun clip(value: F64): F64 =>
    if value < -1.0 then
      -1.0
    elseif value > 1.0 then
      1.0
    else
      value
    end

class StopTimer is TimerNotify
  var _a: Main
  new iso create(a: Main) =>
    _a = a

  fun ref apply(timer: Timer, count: U64): Bool =>
    _a.done()
    false

  fun ref cancel(timer: Timer) =>
    false

interface Producer
  fun ref produce(buf: Buffer)

primitive EnvAttack
primitive EnvRelease
primitive EnvDone
type EnvStage is (EnvAttack | EnvRelease | EnvDone)

class EnvVCA is Producer
  let _attack_delta: F64
  let _release_delta: F64
  var _gain: F64
  var _stage: EnvStage
  let _producer: Producer

  new create(producer: Producer, attack_time: F64, release_time: F64) =>
    _attack_delta = 1.0 / (attack_time * 44100.0)
    _release_delta = 1.0 / (release_time * 44100.0)
    _gain = 0.0
    _stage = EnvAttack
    _producer = producer

  fun ref produce(buf: Buffer) =>
    // Pull buffer from input.
    _producer.produce(buf)

    // Apply envelope in place.
    try
      for i in Range[USize](0, buf.size()) do
        buf.update(i, buf(i) * _gain)
        match _stage
        | EnvAttack =>
          _gain = _gain + _attack_delta
          if _gain >= 1.0 then
            _gain = 1.0
            _stage = EnvRelease
          end
        | EnvRelease =>
          _gain = _gain - _release_delta
          if _gain <= 0.0 then
            _gain = 0.0
            _stage = EnvDone
          end
        end
      end
    end

class Oscillator is Producer
  var _phasor: F64
  var _phasor_inc: F64

  new create(freq: F64) =>
    _phasor = 0
    _phasor_inc = freq / 44100.0

  fun ref produce(buf: Buffer) =>
    for i in Range[USize](0, buf.size()) do
      try
        buf.update(i, _phasor)
      end
      _phasor = _phasor + _phasor_inc
      if _phasor >= 0.5 then
        _phasor = _phasor - 1.0
      end
    end

class MixerChannel
  let _buffers: Array[Buffer]
  var _read_index: USize
  var _write_index: USize
  var _producer: Producer

  new create(producer: Producer) =>
    _buffers = recover Array[Buffer] end
    _read_index = 0
    _write_index = 0
    _producer = producer

  fun ref adopt(frame_count: USize) =>
    for i in Range[USize](0, 2) do
      _buffers.push(recover Buffer(frame_count).init(0.0, frame_count) end)
    end
    try
      pull()
      pull()
    end

  fun ref next(): (None | Buffer) ? =>
    if _read_index == _write_index then
      None
    else
      let result =_buffers(_read_index)
      _read_index = _read_index + 1
      if _read_index == _buffers.size() then
        _read_index = 0
      end
      result
    end

  fun ref pull(): Bool ? =>
    // Figure out what the next buffer is, or if we're full.
    var next_write_index: USize = _write_index + 1
    if next_write_index == _buffers.size() then
      next_write_index = 0
    end
    if next_write_index == _read_index then
      return false
    end
    // Fill the next buffer.
    _producer.produce(_buffers(_write_index))
    _write_index = next_write_index
    true

class Mixer
  """A very basic pull-model audio mixer."""
  let _env: Env
  let _frame_count: USize
  let _channels: Array[MixerChannel]
  let _mixbuf: Buffer
  var _channel_gain: F64

  new create(env: Env, frame_count: USize) =>
    _env = env
    _frame_count = frame_count
    _channels = Array[MixerChannel]
    _mixbuf = Buffer.init(0.0, _frame_count)
    _channel_gain = 1.0

  fun ref add_channel(channel: MixerChannel) =>
    channel.adopt(_frame_count)
    _channels.push(channel)
    _channel_gain = 1.0 / _channels.size().f64()

  fun ref produce(buf: OutBuffer) =>
    try
      for i in Range[USize](0, _frame_count) do
        _mixbuf.update(i, 0.0)
      end
      for c in _channels.values() do
        match c.next()
        | let ch_buf: Buffer =>
          for i in Range[USize](0, _frame_count) do
            _mixbuf.update(i, _mixbuf(i) + ch_buf(i))
          end
        end
      end
      for i in Range[USize](0, _frame_count) do
        buf.update(i, Clipper.clip(_mixbuf(i) * _channel_gain).f32())
      end
    end

  fun ref pull() =>
    for c in _channels.values() do
      try
        let result = c.pull()
      end
    end

actor Main
  """Sets up audio stream."""
  let _env: Env
  let _buffer_count: USize
  let _frame_count: USize
  var _preroll: USize
  let _buffers: Array[OutBuffer]
  let _mixer: Mixer
  var _index: USize
  let _timers: Timers
  let _timer: Timer tag
  let _timestamps: Array[(U64, U64)]

  new create(env: Env) =>
    _env = env
    _buffer_count = 2 
    _frame_count = 1024 
    _preroll = 0 // Will be filled in by preroll().
    _buffers = recover Array[OutBuffer] end
    _index = 0
    _timers = Timers
    let t = Timer(StopTimer(this), 15_000_000_000, 0)
    _timer = t
    _timers(consume t)
    _timestamps = recover Array[(U64, U64)] end

    // Set up audio mixer.
    _mixer = Mixer(_env, _frame_count)
    let random = MT
    let channels: USize = 12
    let freqs = Array[F64]
    freqs.push(55.0)
    freqs.push(92.5)
    freqs.push(92.5)
    freqs.push(123.47)
    freqs.push(123.47)
    freqs.push(246.94)
    freqs.push(246.94)
    freqs.push(246.94 * 8.0)
    freqs.push(92.5 * 8.0)
    for i in Range[USize](0, channels) do
      try
        // Pick a note.
        let base_freq = freqs(random.int(freqs.size().u64()).usize())
        // Randomly perturb frequency.
        let freq: F64 = base_freq + ((random.real() * 4.0) - 2.0)
        // Build osc -> VCA chain and add to mixer.
        let osc = Oscillator(freq)
        let env_vca = EnvVCA(osc, 4.0 + (random.real() * 3.0), 5.0 + (random.real() * 2.0))
        _mixer.add_channel(MixerChannel(env_vca))
      end
    end

    // Set up audio stream.
    let open_result = @init_output_stream[I32](
      _frame_count,
      _buffer_count,
      addressof this.add_buffer,
      addressof this.preroll,
      addressof this.produce,
      this)
    _env.out.print("got open_result: " + open_result.string())

    // The stream will be started by produce() when the preroll phase is done.

  be done() =>
    _env.out.print("stop!")
    if _timestamps.size() > 0 then
      try
        _env.out.print(_timestamps.size().string() + " timestamps recorded.")
        var in_in_delta_min: U64 = U64.max_value()
        var in_in_delta_max: U64 = U64.min_value()
        var in_in_delta_sum: U64 = 0
        var out_in_delta_min: U64 = U64.max_value()
        var out_in_delta_max: U64 = U64.min_value()
        var out_in_delta_sum: U64 = 0
        var last = _timestamps(0)
        for i in Range[USize](2, _timestamps.size()) do
          let t = _timestamps(i)
          let in_in_delta = t._1 - last._1
          if in_in_delta < in_in_delta_min then
            in_in_delta_min = in_in_delta
          end
          if in_in_delta > in_in_delta_max then
            in_in_delta_max = in_in_delta
          end
          in_in_delta_sum = in_in_delta_sum + in_in_delta
          let out_in_delta = t._2 - t._1
          if out_in_delta < out_in_delta_min then
            out_in_delta_min = out_in_delta
          end
          if out_in_delta > out_in_delta_max then
            out_in_delta_max = out_in_delta
          end
          out_in_delta_sum = out_in_delta_sum + out_in_delta
          last = _timestamps(i)
          _env.out.print("in_in " + in_in_delta.string() + " out_in " + out_in_delta.string())
        end
        let in_in_delta_mean: U64 = (in_in_delta_sum.f64() / _timestamps.size().f64()).u64()
        let out_in_delta_mean: U64 = (out_in_delta_sum.f64() / _timestamps.size().f64()).u64()
        _env.out.print("in_in_delta min " + in_in_delta_min.string() +
          " max " + in_in_delta_max.string() + " mean " + in_in_delta_mean.string())
        _env.out.print("out_in_delta min " + out_in_delta_min.string() +
          " max " + out_in_delta_max.string() + " mean " + out_in_delta_mean.string())
      end
    end
    @stop_output_stream[None]()

  be add_buffer(buf: Pointer[F32] iso, ready: Pointer[U8] iso) =>
    let frame_count = _frame_count
    let buf_array: OutBuffer iso = recover
      OutBuffer.from_cstring(consume buf, frame_count)
    end
    _buffers.push(consume buf_array)

  be preroll() =>
    _preroll = _buffers.size()
    _env.out.print("preroll out! " + _preroll.string() + " buffers.")

  be produce(timestamp: F64) =>
    try
      let in_timestamp: U64 = Time.nanos()
      let buf = _buffers(_index)

      _mixer.produce(buf)

      // Advance buffer pointer.
      _index = _index + 1
      if _index == _buffers.size() then
        _index = 0
      end

      // If we're prerolling, see if it's time to start the stream.
      if _preroll > 0 then
        _preroll = _preroll - 1
        if _preroll == 0 then
          _env.out.print("start...")
          let start_result = @start_output_stream[I32]()
          _env.out.print("got start_result: " + start_result.string())
        end
      end

      // Record timing info for this frame.
      let out_timestamp: U64 = Time.nanos()
      _timestamps.push((in_timestamp, out_timestamp))

      // Schedule a pull.
      // pull()

      // Pull synchronously.
      _mixer.pull()
    end

  be pull() =>
    _mixer.pull()
