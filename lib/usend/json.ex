defmodule Usend.JSON do
  @moduledoc """
  A small JSON encoder and decoder, used so the SDK works on every Elixir >= 1.14 without dependencies
  (the standard library `JSON` module only exists from Elixir 1.18).

  Decoding returns maps with string keys, lists, binaries, integers, floats, booleans and `nil`.
  Encoding accepts maps (atom or string keys), lists, binaries, numbers, booleans, `nil` and atoms.
  """

  @doc "Encodes a term to a JSON binary. Raises `ArgumentError` for unsupported terms."
  @spec encode(term()) :: binary()
  def encode(term), do: IO.iodata_to_binary(enc(term))

  @doc "Decodes a JSON binary. Returns `{:ok, term}` or `{:error, reason}`."
  @spec decode(binary()) :: {:ok, term()} | {:error, String.t()}
  def decode(binary) when is_binary(binary) do
    try do
      {value, rest} = value(skip_ws(binary))

      case skip_ws(rest) do
        "" -> {:ok, value}
        _ -> {:error, "unexpected trailing characters"}
      end
    catch
      {:json_error, reason} -> {:error, reason}
    end
  end

  # ---- encoder ----

  defp enc(nil), do: "null"
  defp enc(true), do: "true"
  defp enc(false), do: "false"
  defp enc(i) when is_integer(i), do: Integer.to_string(i)
  defp enc(f) when is_float(f), do: Float.to_string(f)
  defp enc(a) when is_atom(a), do: quote_string(Atom.to_string(a))
  defp enc(s) when is_binary(s), do: quote_string(s)

  defp enc(map) when is_map(map) do
    body =
      map
      |> Enum.map(fn {k, v} -> [quote_string(to_string(k)), ":", enc(v)] end)
      |> Enum.intersperse(",")

    ["{", body, "}"]
  end

  defp enc(list) when is_list(list) do
    if list != [] and Keyword.keyword?(list) do
      enc(Map.new(list))
    else
      ["[", list |> Enum.map(&enc/1) |> Enum.intersperse(","), "]"]
    end
  end

  defp enc(other), do: raise(ArgumentError, "cannot encode #{inspect(other)} as JSON")

  defp quote_string(s) do
    unless String.valid?(s), do: raise(ArgumentError, "JSON strings must be valid UTF-8")
    ["\"", escape(s, []), "\""]
  end

  defp escape(<<>>, acc), do: Enum.reverse(acc)
  defp escape(<<?", rest::binary>>, acc), do: escape(rest, ["\\\"" | acc])
  defp escape(<<?\\, rest::binary>>, acc), do: escape(rest, ["\\\\" | acc])
  defp escape(<<?\n, rest::binary>>, acc), do: escape(rest, ["\\n" | acc])
  defp escape(<<?\r, rest::binary>>, acc), do: escape(rest, ["\\r" | acc])
  defp escape(<<?\t, rest::binary>>, acc), do: escape(rest, ["\\t" | acc])
  defp escape(<<?\b, rest::binary>>, acc), do: escape(rest, ["\\b" | acc])
  defp escape(<<?\f, rest::binary>>, acc), do: escape(rest, ["\\f" | acc])

  defp escape(<<c, rest::binary>>, acc) when c < 0x20 do
    hex = c |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()
    escape(rest, ["\\u" <> hex | acc])
  end

  defp escape(<<c::utf8, rest::binary>>, acc), do: escape(rest, [<<c::utf8>> | acc])

  # ---- decoder ----

  defp skip_ws(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_ws(rest)
  defp skip_ws(bin), do: bin

  defp value(<<"{", rest::binary>>), do: object(skip_ws(rest), %{})
  defp value(<<"[", rest::binary>>), do: array(skip_ws(rest), [])
  defp value(<<"\"", rest::binary>>), do: string(rest, [])
  defp value(<<"true", rest::binary>>), do: {true, rest}
  defp value(<<"false", rest::binary>>), do: {false, rest}
  defp value(<<"null", rest::binary>>), do: {nil, rest}
  defp value(<<c, _::binary>> = bin) when c == ?- or c in ?0..?9, do: number(bin)
  defp value(<<>>), do: throw({:json_error, "unexpected end of JSON"})
  defp value(<<c, _::binary>>), do: throw({:json_error, "unexpected character #{<<c>>}"})

  defp object(<<"}", rest::binary>>, acc), do: {acc, rest}

  defp object(<<"\"", rest::binary>>, acc) do
    {key, rest} = string(rest, [])

    case skip_ws(rest) do
      <<":", rest::binary>> ->
        {val, rest} = value(skip_ws(rest))
        acc = Map.put(acc, key, val)

        case skip_ws(rest) do
          <<",", rest::binary>> -> object(skip_ws(rest), acc)
          <<"}", rest::binary>> -> {acc, rest}
          _ -> throw({:json_error, "expected ',' or '}'"})
        end

      _ ->
        throw({:json_error, "expected ':'"})
    end
  end

  defp object(_, _), do: throw({:json_error, "expected a string key"})

  defp array(<<"]", rest::binary>>, []), do: {[], rest}

  defp array(bin, acc) do
    {val, rest} = value(bin)

    case skip_ws(rest) do
      <<",", rest::binary>> -> array(skip_ws(rest), [val | acc])
      <<"]", rest::binary>> -> {Enum.reverse([val | acc]), rest}
      _ -> throw({:json_error, "expected ',' or ']'"})
    end
  end

  defp string(<<"\"", rest::binary>>, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp string(<<"\\u", hex::binary-size(4), rest::binary>>, acc) do
    cp = hex_to_int(hex)

    if cp in 0xD800..0xDBFF do
      case rest do
        <<"\\u", hex2::binary-size(4), rest2::binary>> ->
          lo = hex_to_int(hex2)

          if lo in 0xDC00..0xDFFF do
            full = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            string(rest2, [<<full::utf8>> | acc])
          else
            throw({:json_error, "invalid surrogate pair"})
          end

        _ ->
          throw({:json_error, "invalid surrogate pair"})
      end
    else
      if cp in 0xDC00..0xDFFF, do: throw({:json_error, "invalid surrogate pair"})
      string(rest, [<<cp::utf8>> | acc])
    end
  end

  defp string(<<"\\", c, rest::binary>>, acc) do
    ch =
      case c do
        ?" -> "\""
        ?\\ -> "\\"
        ?/ -> "/"
        ?b -> "\b"
        ?f -> "\f"
        ?n -> "\n"
        ?r -> "\r"
        ?t -> "\t"
        _ -> throw({:json_error, "invalid escape"})
      end

    string(rest, [ch | acc])
  end

  defp string(<<c::utf8, rest::binary>>, acc), do: string(rest, [<<c::utf8>> | acc])
  defp string(_, _), do: throw({:json_error, "unterminated or invalid string"})

  defp hex_to_int(hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> n
      _ -> throw({:json_error, "invalid unicode escape"})
    end
  end

  defp number(bin) do
    {num, rest} = take_number(bin, [])
    str = num |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      String.contains?(str, [".", "e", "E"]) ->
        # Float.parse needs a digit after the dot and handles exponents.
        case Float.parse(str) do
          {f, ""} -> {f, rest}
          _ -> throw({:json_error, "invalid number"})
        end

      true ->
        case Integer.parse(str) do
          {i, ""} -> {i, rest}
          _ -> throw({:json_error, "invalid number"})
        end
    end
  end

  defp take_number(<<c, rest::binary>>, acc) when c in ?0..?9 or c in [?-, ?+, ?., ?e, ?E],
    do: take_number(rest, [<<c>> | acc])

  defp take_number(rest, acc), do: {acc, rest}
end
