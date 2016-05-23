use "collections"
use "time"
use "lib:portaudio_sink"
use "lib:portaudio"

type Buffer is (Array[F32], Array[U8])

class StopTimer is TimerNotify
  var _a: Main
  new iso create(a: Main) =>
    _a = a

  fun ref apply(timer: Timer, count: U64): Bool =>
    _a.done()
    false

  fun ref cancel(timer: Timer) =>
    false

actor Main
  """Sets up audio stream."""
  var _env: Env
  let _buffer_count: USize
  let _frame_count: USize
  var _preroll: USize
  var _buffers: Array[Buffer]
  var _index: USize
  var _timers: Timers
  var _timer: Timer tag
  var _phasor: F64
  let _phasor_inc: F64
  let _gain: F64
  var _timestamps: Array[(U64, U64)]

  new create(env: Env) =>
    _env = env
    _buffer_count = 2 
    _frame_count = 1024 
    _preroll = 0 // Will be filled in by preroll().
    _buffers = recover Array[Buffer] end
    _index = 0
    _phasor = 0.0
    _phasor_inc = 880.0 / 44100.0
    _gain = 0.05
    _timers = Timers
    let t = Timer(StopTimer(this), 15_000_000_000, 0)
    _timer = t
    _timers(consume t)
    _timestamps = recover Array[(U64, U64)] end

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
    let buf_array: Array[F32] iso = recover
      Array[F32].from_cstring(consume buf, frame_count)
    end
    let ready_array: Array[U8] iso = recover
      Array[U8].from_cstring(consume ready, USize(1))
    end
    _buffers.push((consume buf_array, consume ready_array))

  be preroll() =>
    _preroll = _buffers.size()
    _env.out.print("preroll out! " + _preroll.string() + " buffers.")

  be produce(timestamp: F64) =>
    try
      let in_timestamp: U64 = Time.nanos()
      let buf = _buffers(_index)
      // Fill the next buffer.
      for i in Range[USize](0, _frame_count) do
        buf._1.update(i, (_phasor * _gain).f32())
        _phasor = _phasor + _phasor_inc
        if _phasor > 1.0 then
          _phasor = _phasor - 1.0
        end
      end
      // Set the "ready" flag on the buffer.
      //buf._2.update(0, U8(1))
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
      let out_timestamp: U64 = Time.nanos()
      _timestamps.push((in_timestamp, out_timestamp))
    end
