defmodule Axon.Updates do
  @moduledoc ~S"""
  Parameter update methods.

  Update methods transform the input tensor in some way,
  usually by scaling or shifting the input with respect
  to some input state. Update methods are composed
  to create more advanced optimization methods such as AdaGrad
  or Adam. Each update returns a tuple:

      {init_fn, update_fn}

  Which represent a state initialization and state update
  function respectively. While each method in the Updates
  API is a regular Elixir function, the two methods they
  return are implemented as `defn`, so they can be accelerated
  using any Nx backend or compiler.

  Update methods are just combinators that can be arbitrarily
  composed to create complex optimizers. For example, the Adam
  optimizer in Axon.Optimizers is implemented as:

      def adam(learning_rate, opts \\ []) do
        Updates.scale_by_adam(opts)
        |> Updates.scale(-learning_rate)
      end

  Updates are maps of updates, often associated with parameters of
  the same names. Using `Axon.Updates.apply_updates/2` will merge updates
  and parameters by adding associated parameters and updates.

  ## Custom combinators

  You can create your own combinators using the `stateless/2` and
  `stateful/3` primitives. Every update method in this module is
  implemented in terms of one of these two primitives.

  `stateless/2` represents a stateless update:

      def scale(combinator \\ Axon.Updates.identity(), step_size) do
        stateless(combinator, &apply_scale(&1, &2, step_size))
      end

      defnp apply_scale(x, _params, step) do
        transform(
          {x, step},
          fn {updates, step} ->
            deep_new(updates, fn {k, x} -> Nx.multiply(x, step) end)
          end
        )
      end

  Notice how the function given to `stateless/2` is defined within `defn`.
  This is what allows the anonymous functions returned by `Axon.Updates`
  to be used inside `defn`.

  `stateful/3` represents a stateful update and follows the same pattern:

      def my_stateful_update(updates) do
        Axon.Updates.stateful(updates, &init_my_update/1, &apply_my_update/2)
      end

      defnp init_my_update(params) do
        state = zeros_like(params)
        %{state: state}
      end

      defnp apply_my_update(updates, state) do
        new_state = deep_new(state, fn {k, v} -> {k, Nx.add(v, 0.01)} end)
        updates = transform({updates, new_state}, fn {updates, state} ->
          deep_merge(updates, state, fn _, g, z -> Nx.multiply(g, z) end)
        end)
        {updates, %{state: new_state}}
      end

  State associated with individual parameters should have keys that match the
  keys of the parameter. For example, if you have parameters `%{kernel: kernel}`
  with associated states `mu` and `nu` representing the first and second moments,
  your state should look something like:

      %{
        mu: %{kernel: kernel_mu}
        nu: %{kernel: kernel_nu}
      }
  """
  import Nx.Defn
  import Axon.Shared

  @doc ~S"""
  Scales input by a fixed step size.

  $$f(x_i) = \alpha x_i$$
  """
  def scale(combinator \\ identity(), step_size) do
    stateless(combinator, &apply_scale(&1, &2, step_size))
  end

  defnp apply_scale(x, _params, step) do
    transform(
      {x, step},
      fn {updates, step} ->
        deep_new(updates, fn {k, v} -> {k, Nx.multiply(v, step)} end)
      end
    )
  end

  @doc """
  Scales input according to Adam algorithm.

  ## Options

      * `:b1` - first moment decay. Defaults to `0.9`
      * `:b2` - second moment decay. Defaults to `0.999`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`
      * `:eps_root` - numerical stability term. Defaults to `1.0e-10`

  ## References

    * [Adam: A Method for Stochastic Optimization](https://arxiv.org/abs/1412.6980)

  """
  def scale_by_adam(combinator \\ identity(), opts) do
    stateful(
      combinator,
      &init_scale_by_adam/1,
      &apply_scale_by_adam(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_adam(params) do
    mus = zeros_like(params)
    nus = zeros_like(params)
    count = Nx.tensor(0)
    %{mu: mus, nu: nus, count: count}
  end

  defnp apply_scale_by_adam(x, %{mu: mu, nu: nu, count: count}, _params, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 1.0e-8, eps_root: 1.0e-15)
    b1 = opts[:b1]
    b2 = opts[:b2]
    eps = opts[:eps]
    eps_root = opts[:eps_root]

    mu = update_moment(x, mu, b1, 1)
    nu = update_moment(x, nu, b2, 2)

    mu_hat = bias_correction(mu, b1, count + 1)
    nu_hat = bias_correction(nu, b2, count + 1)

    x =
      transform({mu_hat, nu_hat, eps, eps_root}, fn {mu_hat, nu_hat, eps, eps_root} ->
        deep_merge(mu_hat, nu_hat, fn z, t -> z / (Nx.sqrt(t + eps_root) + eps) end)
      end)

    {x, %{mu: mu, nu: nu, count: count + 1}}
  end

  @doc """
  Scales input by the root of all prior squared inputs.

  ## Options

      * `:eps` - numerical stability term. Defaults to `1.0e-7`

  """
  def scale_by_rss(combinator \\ identity(), opts) do
    {initial, opts} = Keyword.pop(opts, :initial_accumulator_value, 0.1)

    stateful(
      combinator,
      &init_scale_by_rss(&1, initial),
      &apply_scale_by_rss(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_rss(params, value) do
    sum_of_squares = fulls_like(params, value)
    %{sum_of_squares: sum_of_squares}
  end

  defnp apply_scale_by_rss(x, %{sum_of_squares: sum_of_squares}, _params, opts \\ []) do
    opts = keyword!(opts, eps: 1.0e-7)
    eps = opts[:eps]

    sum_of_squares =
      transform({x, sum_of_squares}, fn {x, sum_of_squares} ->
        deep_merge(x, sum_of_squares, fn g, z -> Nx.power(g, 2) + z end)
      end)

    inv_sqrt_squares =
      transform({sum_of_squares, eps}, fn {sum_of_squares, eps} ->
        deep_new(sum_of_squares, fn {k, z} -> {k, Nx.rsqrt(z + eps)} end)
      end)

    inv_sqrt_x_square =
      transform({sum_of_squares, inv_sqrt_squares}, fn {sum_of_squares, inv_sqrt_squares} ->
        deep_merge(sum_of_squares, inv_sqrt_squares, fn z, t ->
          Nx.select(Nx.greater(z, 0), t, 0.0)
        end)
      end)

    x =
      transform({x, inv_sqrt_x_square}, fn {x, inv_sqrt_x_square} ->
        deep_merge(x, inv_sqrt_x_square, fn g, t -> g * t end)
      end)

    {x, %{sum_of_squares: sum_of_squares}}
  end

  @doc """
  Scales input by the root of the EMA of squared inputs.

  ## Options

      * `:decay` - EMA decay rate. Defaults to `0.9`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`

  ## References

    * [Overview of mini-batch gradient descent](www.cs.toronto.edu/~tijmen/csc321/slides/lecture_slides_lec6.pdf)

  """
  def scale_by_rms(combinator \\ identity(), opts) do
    {initial, opts} = Keyword.pop(opts, :initial_scale, 0.0)

    stateful(
      combinator,
      &init_scale_by_rms(&1, initial),
      &apply_scale_by_rms(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_rms(params, scale) do
    nu = fulls_like(params, scale)
    %{nu: nu}
  end

  defnp apply_scale_by_rms(x, %{nu: nu}, _params, opts \\ []) do
    opts = keyword!(opts, decay: 0.9, eps: 1.0e-8)
    decay = opts[:decay]
    eps = opts[:eps]

    nu = update_moment(x, nu, decay, 2)

    x =
      transform({x, nu, eps}, fn {x, nu, eps} ->
        deep_merge(x, nu, fn g, t -> Nx.rsqrt(t + eps) * g end)
      end)

    {x, %{nu: nu}}
  end

  @doc """
  Scales input according to the AdaBelief algorithm.

  ## Options

      * `:b1` - first moment decay. Defaults to `0.9`
      * `:b2` - second moment decay. Defaults to `0.999`
      * `:eps` - numerical stability term. Defaults to `0.0`
      * `:eps_root` - numerical stability term. Defaults to `1.0e-16`

  ## References

    * [AdaBelief Optimizer: Adapting Stepsizes by the Belief in Observed Gradients](https://arxiv.org/abs/2010.07468)

  """
  def scale_by_belief(combinator \\ identity(), opts) do
    stateful(
      combinator,
      &init_scale_by_belief/1,
      &apply_scale_by_belief(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_belief(params) do
    mus = zeros_like(params)
    nus = zeros_like(params)
    count = Nx.tensor(0)
    %{mu: mus, nu: nus, count: count}
  end

  defnp apply_scale_by_belief(x, %{mu: mu, nu: nu, count: count}, _params, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 0.0, eps_root: 1.0e-16)
    b1 = opts[:b1]
    b2 = opts[:b2]
    eps = opts[:eps]
    eps_root = opts[:eps_root]

    mu = update_moment(x, mu, b1, 1)
    nu = update_moment(x, nu, b2, 2)

    mu_hat = bias_correction(mu, b1, count + 1)
    nu_hat = bias_correction(nu, b2, count + 1)

    x =
      transform({mu_hat, nu_hat, eps, eps_root}, fn {mu_hat, nu_hat, eps, eps_root} ->
        deep_merge(mu_hat, nu_hat, fn z, t -> 1 / (Nx.sqrt(t + eps_root) + eps) * z end)
      end)

    {x, %{mu: mu, nu: nu, count: count + 1}}
  end

  @doc """
  Scales input by the root of the centered EMA of squared inputs.

  ## Options

      * `:decay` - EMA decay rate. Defaults to `0.9`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`

  ## References

    * [Overview of mini-batch gradient descent](www.cs.toronto.edu/~tijmen/csc321/slides/lecture_slides_lec6.pdf)

  """
  def scale_by_stddev(combinator \\ identity(), opts) do
    {initial, opts} = Keyword.pop(opts, :initial_scale, 0.0)

    stateful(
      combinator,
      &init_scale_by_stddev(&1, initial),
      &apply_scale_by_stddev(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_stddev(params, value) do
    mu = zeros_like(params)
    nu = fulls_like(params, value)
    %{mu: mu, nu: nu}
  end

  defnp apply_scale_by_stddev(x, %{mu: mu, nu: nu}, _params, opts \\ []) do
    opts = keyword!(opts, decay: 0.9, eps: 1.0e-8)
    decay = opts[:decay]
    eps = opts[:eps]

    mu = update_moment(x, mu, decay, 1)
    nu = update_moment(x, nu, decay, 2)

    x =
      transform({x, mu, nu, eps}, fn {x, mu, nu, eps} ->
        mu_nu =
          deep_merge(mu, nu, fn m, n ->
            Nx.rsqrt(-Nx.power(m, 2) + n + eps)
          end)

        deep_merge(x, mu_nu, fn g, mn -> g * mn end)
      end)

    {x, %{mu: mu, nu: nu}}
  end

  @doc """
  Scales input using the given schedule function.
  """
  def scale_by_schedule(combinator \\ identity(), schedule_fn) when is_function(schedule_fn) do
    stateful(
      combinator,
      &init_scale_by_schedule/1,
      &apply_scale_by_schedule(&1, &2, &3, schedule_fn)
    )
  end

  defnp init_scale_by_schedule(_) do
    %{count: Nx.tensor(0)}
  end

  defnp apply_scale_by_schedule(x, %{count: count}, _params, schedule_fn) do
    step_size = schedule_fn.(count)

    updates =
      transform({x, step_size}, fn {x, step_size} ->
        deep_new(x, fn {k, x} -> {k, x * step_size} end)
      end)

    {updates, %{count: count + 1}}
  end

  @doc """
  Scale input according to the Rectified Adam algorithm.

  ## Options

      * `:b1` - first moment decay. Defaults to `0.9`
      * `:b2` - second moment decay. Defaults to `0.999`
      * `:eps` - numerical stability term. Defaults to `1.0e-8`
      * `:eps_root` - numerical stability term. Defaults to `0.0`
      * `:threshold` - threshold for variance. Defaults to `5.0`

  ## References

    * [On the Variance of the Adaptive Learning Rate and Beyond](https://arxiv.org/abs/1908.03265)

  """
  def scale_by_radam(combinator \\ identity(), opts) do
    stateful(
      combinator,
      &init_scale_by_radam/1,
      &apply_scale_by_radam(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_radam(params) do
    mu = zeros_like(params)
    nu = zeros_like(params)
    count = Nx.tensor(0)
    %{mu: mu, nu: nu, count: count}
  end

  defnp apply_scale_by_radam(x, %{mu: mu, nu: nu, count: count}, _params, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 1.0e-8, eps_root: 0.0, threshold: 5.0)
    b1 = opts[:b1]
    b2 = opts[:b2]
    eps = opts[:eps]
    eps_root = opts[:eps_root]
    threshold = opts[:threshold]

    ro_inf = 2.0 / (1 - b1) - 1

    mu = update_moment(x, mu, b1, 1)
    nu = update_moment(x, nu, b2, 2)
    count_inc = count + 1

    b2t = Nx.power(b2, count_inc)
    ro = ro_inf - 2 * count_inc * b2t / (1 - b2t)

    mu_hat = bias_correction(mu, b1, count + 1)
    nu_hat = bias_correction(nu, b2, count + 1)

    x =
      if Nx.all(Nx.greater_equal(ro, threshold)) do
        radam_update(ro, ro_inf, mu_hat, nu_hat, eps_root, eps)
      else
        mu_hat
      end

    {x, %{mu: mu, nu: nu, count: count + 1}}
  end

  defnp radam_update(ro, ro_inf, mu, nu, eps_root, eps) do
    r = Nx.sqrt((ro - 4) * (ro - 2) * ro_inf / ((ro_inf - 4) * (ro_inf - 2) * ro))

    transform({r, mu, nu, eps_root, eps}, fn {r, mu, nu, eps_root, eps} ->
      deep_merge(mu, nu, fn m, v ->
        r * m / (Nx.sqrt(v + eps_root) + eps)
      end)
    end)
  end

  @doc """
  Trace inputs with past inputs.

  ## Options

    * `:decay` - decay rate for tracing past updates. Defaults
      to `0.9`
    * `:nesterov` - whether to use Nesterov momentum. Defaults
      to `false`

  """
  def trace(combinator \\ identity(), opts) do
    stateful(
      combinator,
      &init_trace/1,
      &apply_trace(&1, &2, &3, opts)
    )
  end

  defnp init_trace(params) do
    trace = zeros_like(params)
    %{trace: trace}
  end

  defnp apply_trace(x, %{trace: trace}, _params, opts \\ []) do
    opts = keyword!(opts, decay: 0.9, nesterov: false)
    decay = opts[:decay]

    update_trace =
      transform({x, trace, decay}, fn {x, trace, decay} ->
        deep_merge(x, trace, fn g, t -> t * decay + g end)
      end)

    x =
      transform({x, update_trace, decay, opts}, fn {x, trace, decay, opts} ->
        if opts[:nesterov] do
          deep_merge(x, trace, fn g, t -> t * decay + g end)
        else
          trace
        end
      end)

    {x, %{trace: update_trace}}
  end

  @doc """
  Clips input between -delta and delta.

  ## Options

    * `:delta` - maximum absolute value of the input. Defaults
      to `2.0`
  """
  def clip(combinator \\ identity(), opts) do
    stateless(combinator, &apply_clip(&1, &2, opts))
  end

  defnp apply_clip(x, _params, opts \\ []) do
    opts = keyword!(opts, delta: 2.0)
    delta = opts[:delta]

    transform({x, delta}, fn {x, delta} ->
      deep_new(x, fn {k, g} -> {k, Nx.clip(g, -delta, delta)} end)
    end)
  end

  @doc """
  Clips input using input global norm.

  ## Options

    * `:max_norm` - maximum norm value of input. Defaults to
      `1.0`
  """
  def clip_by_global_norm(combinator \\ identity(), opts) do
    stateless(combinator, &apply_clip_by_global_norm(&1, &2, opts))
  end

  defnp apply_clip_by_global_norm(x, _params, opts \\ []) do
    opts = keyword!(opts, max_norm: 1.0)
    max_norm = opts[:max_norm]

    g_norm =
      transform(x, fn x ->
        sum_gs =
          deep_reduce(x, Nx.tensor(0.0), fn leaf, acc ->
            leaf
            |> Nx.power(2)
            |> Nx.sum()
            |> Nx.add(acc)
          end)

        Nx.sqrt(sum_gs)
      end)

    transform({x, g_norm, max_norm}, fn {x, g_norm, max_norm} ->
      deep_new(x, fn {k, z} ->
        {k, Nx.select(Nx.less(g_norm, max_norm), z, z / g_norm * max_norm)}
      end)
    end)
  end

  @doc """
  Centralizes input by shifting updates by their mean.
  """
  def centralize(combinator \\ identity()) do
    stateless(combinator, &apply_centralize/2)
  end

  defnp apply_centralize(x, _params) do
    transform(x, fn x ->
      deep_new(x, fn {k, z} ->
        if Elixir.Kernel.>(Nx.rank(z), 1) do
          axes = tl(Nx.axes(z))
          {k, z - Nx.mean(z, axes: axes, keep_axes: true)}
        else
          {k, z}
        end
      end)
    end)
  end

  @doc """
  Weight decay.
  """
  def add_decayed_weights(combinator \\ identity(), opts) do
    stateless(combinator, &apply_weight_decay(&1, &2, opts))
  end

  defnp apply_weight_decay(updates, params, opts \\ []) do
    opts = keyword!(opts, decay: 0.0)
    decay = opts[:decay]

    transform({updates, params, decay}, fn {updates, params, decay} ->
      deep_merge(updates, params, fn g, p -> g + decay * p end)
    end)
  end

  @doc """
  Scale by trust ratio.
  """
  def scale_by_trust_ratio(combinator \\ identity(), opts) do
    stateless(combinator, &apply_scale_by_trust_ratio(&1, &2, opts))
  end

  defnp apply_scale_by_trust_ratio(x, params, opts \\ []) do
    opts = keyword!(opts, min_norm: 0.0, trust_coefficient: 1.0, eps: 0.0)
    min_norm = opts[:min_norm]
    trust_coefficient = opts[:trust_coefficient]
    eps = opts[:eps]

    transform({x, params}, fn {updates, params} ->
      deep_merge(updates, params, fn g, p ->
        param_norm = safe_norm(p, min_norm)
        update_norm = safe_norm(g, min_norm)

        trust_ratio = trust_coefficient * param_norm / (update_norm + eps)

        zero_norm = Nx.logical_or(Nx.equal(param_norm, 0.0), Nx.equal(update_norm, 0.0))
        safe_trust_ratio = Nx.select(zero_norm, 1, trust_ratio)

        Nx.multiply(g, safe_trust_ratio)
      end)
    end)
  end

  @doc """
  Add noise.
  """
  def add_noise(combinator \\ identity(), opts) do
    stateful(combinator, &init_add_noise/1, &apply_add_noise(&1, &2, &3, opts))
  end

  defnp init_add_noise(_params) do
    %{count: Nx.tensor(0)}
  end

  defnp apply_add_noise(x, %{count: count}, _params, opts \\ []) do
    opts = keyword!(opts, eta: 0.01, gamma: 0.55)
    var = opts[:eta] / Nx.power(count + 1, opts[:gamma])

    noise =
      transform(x, fn x ->
        deep_new(x, fn {k, z} -> {k, Nx.random_normal(z)} end)
      end)

    updates =
      transform({x, noise, var}, fn {x, noise, var} ->
        deep_merge(x, noise, fn g, n -> g + var * n end)
      end)

    {updates, %{count: count + 1}}
  end

  @doc """
  Scale by yogi.
  """
  def scale_by_yogi(combinator \\ identity(), opts) do
    {initial, opts} = Keyword.pop(opts, :initial_accumulator_value, 1.0e-6)

    stateful(
      combinator,
      &init_scale_by_yogi(&1, initial),
      &apply_scale_by_yogi(&1, &2, &3, opts)
    )
  end

  defnp init_scale_by_yogi(params, value) do
    value = fulls_like(params, value)
    mu = value
    nu = value
    count = Nx.tensor(0)
    %{mu: mu, nu: nu, count: count}
  end

  defnp apply_scale_by_yogi(x, %{mu: mu, nu: nu, count: count}, _params, opts \\ []) do
    opts = keyword!(opts, b1: 0.9, b2: 0.999, eps: 1.0e-3, eps_root: 0.0)
    b1 = opts[:b1]
    b2 = opts[:b2]
    eps = opts[:eps]
    eps_root = opts[:eps_root]

    mu = update_moment(x, mu, b1, 1)

    nu =
      transform({x, nu, b2}, fn {x, nu, b2} ->
        deep_merge(x, nu, fn g, v ->
          v - (1 - b2) * Nx.sign(v - Nx.power(g, 2)) * Nx.power(g, 2)
        end)
      end)

    mu_hat = bias_correction(mu, b1, count + 1)
    nu_hat = bias_correction(nu, b2, count + 1)

    updates =
      transform({mu_hat, nu_hat, eps, eps_root}, fn {mu_hat, nu_hat, eps, eps_root} ->
        deep_merge(mu_hat, nu_hat, fn m, v -> m / (Nx.sqrt(v + eps_root) + eps) end)
      end)

    {updates, %{mu: mu, nu: nu, count: count + 1}}
  end

  @doc """
  Represents a stateless update.
  """
  def stateless({parent_init_fn, parent_apply_fn} \\ identity(), apply_fn) do
    apply_fn = fn updates, state, params ->
      {updates, state} = parent_apply_fn.(updates, state, params)
      {apply_fn.(updates, params), state}
    end

    {parent_init_fn, apply_fn}
  end

  @doc """
  Returns the identity update.

  This is often as the initial update in many functions in this module.
  """
  def identity() do
    {fn _params -> {} end, fn updates, state, _params -> {updates, state} end}
  end

  def identity(combinator) do
    combinator
  end

  @doc """
  Composes two updates. This is useful for extending optimizers
  without having to reimplement them. For example, you can implement
  gradient centralization:

      import Axon.Updates

      Axon.Updates.compose(Axon.Updates.centralize(), Axon.Optimizers.rmsprop())

  This is equivalent to:

      Axon.Updates.centralize()
      |> Axon.Updates.scale_by_rms()
  """
  def compose({init_fn1, apply_fn1}, {init_fn2, apply_fn2}) do
    init_fn = fn params ->
      state = init_fn1.(params)
      Tuple.insert_at(state, 0, init_fn2.(params))
    end

    apply_fn = fn updates, state, params ->
      this_state = elem(state, 0)
      other_state = Tuple.delete_at(state, 0)
      {updates, new_other_state} = apply_fn1.(updates, other_state, params)
      {updates, new_this_state} = apply_fn2.(updates, this_state, params)
      {updates, Tuple.insert_at(new_other_state, 0, new_this_state)}
    end

    {init_fn, apply_fn}
  end

  @doc """
  Represents a stateful update.
  """
  def stateful({parent_init_fn, parent_apply_fn} \\ identity(), init_fn, apply_fn) do
    init_fn = fn params ->
      state = parent_init_fn.(params)
      Tuple.insert_at(state, 0, init_fn.(params))
    end

    apply_fn = fn updates, state, params ->
      this_state = elem(state, 0)
      other_state = Tuple.delete_at(state, 0)
      {updates, new_other_state} = parent_apply_fn.(updates, other_state, params)
      {updates, new_this_state} = apply_fn.(updates, this_state, params)
      {updates, Tuple.insert_at(new_other_state, 0, new_this_state)}
    end

    {init_fn, apply_fn}
  end

  @doc """
  Applies updates to params and updates state parameters with
  given state map.
  """
  defn apply_updates(params, updates, state \\ nil) do
    new_params =
      transform({params, updates}, fn {params, updates} ->
        deep_merge(params, updates, fn x, u ->
          Nx.add(x, Nx.as_type(u, Nx.type(x)))
        end)
      end)

    transform({new_params, state}, fn
      {new_params, nil} ->
        new_params

      {new_params, state} ->
        Map.merge(new_params, state, fn _, s1, s2 ->
          Map.merge(s1, s2, fn _, _, s -> s end)
        end)
    end)
  end

  ## Helpers

  defnp update_moment(x, moment, decay, order) do
    transform({x, moment, decay, order}, fn {x, moment, decay, order} ->
      deep_merge(x, moment, fn g, z -> (1 - decay) * Nx.power(g, order) + decay * z end)
    end)
  end

  defnp bias_correction(moment, decay, count) do
    transform({moment, decay, count}, fn {moment, decay, count} ->
      deep_new(moment, fn {k, z} -> {k, z / (1 - Nx.power(decay, count))} end)
    end)
  end

  defnp safe_norm(g, min_norm) do
    norm = Nx.LinAlg.norm(g)
    z = Nx.select(Nx.less_equal(norm, min_norm), 1, g)
    masked_norm = Nx.LinAlg.norm(z)
    Nx.select(Nx.less_equal(norm, min_norm), min_norm, masked_norm)
  end
end
