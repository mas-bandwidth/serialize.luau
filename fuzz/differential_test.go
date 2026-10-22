// Package fuzz holds the differential fuzz test for the Luau serialize port
// (DESIGN.md; this card). TestDifferentialAgainstSerializeGo generates random
// programs from a fixed seed, writes them with serialize.go v2.0.0 and with the
// Luau port via fuzz/driver.luau, and compares bytes, read-back traces and
// mutated-read decisions. Every read ends with SerializeEnd (STANDARD.md end),
// and a refusal is traced with its reason (STANDARD.md, Refusal reasons), so
// the two readers must agree on the reason as well as the decision. TestDifferentialNegativeControl sets a test-only flag
// that makes the Go side write one int range one bit wider and asserts the
// harness catches the divergence (the negative control must go red without it).
package fuzz

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	serialize "github.com/mas-bandwidth/serialize.go/v2"
)

const (
	bufferSize  = 4096
	numPrograms = 2000
	batchSize   = 100
)

// widenRange is the test-only negative-control flag: when set, the Go writer
// emits one int range one bit wider than the Luau side writes.
var widenRange bool

// step is one serialization operation. All numeric arguments are carried as
// low-first uint32 words; signed values are their two's-complement patterns.
type step struct {
	op      string
	words   []uint32
	bits    int
	hex     string
	bufsize int
}

type program struct {
	steps    []step
	mutate   []string // nil for a program that is not mutated
	expected string   // the canonical read-back trace
}

// ---------------------------------------------------------------------------
// canonical trace encoders

func tokD(v int64) string  { return "d" + strconv.FormatInt(v, 10) }
func tokU(v uint64) string { return "d" + strconv.FormatUint(v, 10) }
func tokH64(lo, hi uint32) string {
	return "h" + strconv.FormatUint(uint64(lo), 10) + ":" + strconv.FormatUint(uint64(hi), 10)
}
func tokH128(w [4]uint32) string {
	return "H" + strconv.FormatUint(uint64(w[0]), 10) + ":" + strconv.FormatUint(uint64(w[1]), 10) +
		":" + strconv.FormatUint(uint64(w[2]), 10) + ":" + strconv.FormatUint(uint64(w[3]), 10)
}
func tokF(u uint32) string { return fmt.Sprintf("f%08x", u) }
func tokDbl(lo, hi uint32) string {
	return "D" + strconv.FormatUint(uint64(lo), 10) + ":" + strconv.FormatUint(uint64(hi), 10)
}

const hexDigits = "0123456789abcdef"

func hexEncode(b []byte) string {
	if len(b) == 0 {
		return ""
	}
	var sb strings.Builder
	for _, c := range b {
		sb.WriteByte(hexDigits[c>>4])
		sb.WriteByte(hexDigits[c&0xf])
	}
	return sb.String()
}

func hexDecode(s string) []byte {
	out := make([]byte, len(s)/2)
	for i := range out {
		hi := strings.IndexByte(hexDigits, s[2*i])
		lo := strings.IndexByte(hexDigits, s[2*i+1])
		out[i] = byte(hi<<4 | lo)
	}
	return out
}

// ---------------------------------------------------------------------------
// word assembly

func s64(lo, hi uint32) uint64      { return uint64(hi)<<32 | uint64(lo) }
func w64(v uint64) (uint32, uint32) { return uint32(v), uint32(v >> 32) }

func i128w(l0, l1, h0, h1 uint32) serialize.Int128 {
	return serialize.Int128{Lo: s64(l0, l1), Hi: s64(h0, h1)}
}
func u128w(l0, l1, h0, h1 uint32) serialize.Uint128 {
	return serialize.Uint128{Lo: s64(l0, l1), Hi: s64(h0, h1)}
}
func wI128(v serialize.Int128) [4]uint32 {
	l0, l1 := w64(v.Lo)
	h0, h1 := w64(v.Hi)
	return [4]uint32{l0, l1, h0, h1}
}

// ---------------------------------------------------------------------------
// generation

func pick(r *rand.Rand, items []string) string {
	return items[r.IntN(len(items))]
}

func genProgram(r *rand.Rand) program {
	n := 1 + r.IntN(24)
	var steps []step
	for k := 0; k < n; k++ {
		op := pick(r, []string{"b", "b64", "bl", "u8", "u16", "u32", "u64", "i", "i64",
			"i128", "u128", "ir", "f", "d", "fx", "f128", "cf", "by", "s", "al", "ob"})
		st := step{op: op}
		switch op {
		case "b":
			bits := 1 + r.IntN(32)
			var mask uint32
			if bits == 32 {
				mask = ^uint32(0)
			} else {
				mask = (1 << bits) - 1
			}
			st.bits = bits
			st.words = []uint32{r.Uint32() & mask}
		case "b64":
			bits := 1 + r.IntN(64)
			var mask uint64
			if bits == 64 {
				mask = ^uint64(0)
			} else {
				mask = (1 << bits) - 1
			}
			st.bits = bits
			lo, hi := w64(r.Uint64() & mask)
			st.words = []uint32{lo, hi}
		case "bl":
			st.words = []uint32{r.Uint32() % 2}
		case "u8":
			st.words = []uint32{r.Uint32() & 0xff}
		case "u16":
			st.words = []uint32{r.Uint32() & 0xffff}
		case "u32":
			st.words = []uint32{r.Uint32()}
		case "u64":
			lo, hi := w64(r.Uint64())
			st.words = []uint32{lo, hi}
		case "i":
			mn := int32(r.Uint32() & 0x3fffffff)
			if r.Uint32()%20 == 0 {
				st.words = []uint32{uint32(mn), uint32(mn), uint32(mn)}
				break
			}
			span := r.Uint32() & 0x3fffffff
			mx := mn + int32(span)
			var v int32
			switch r.IntN(10) {
			case 0:
				v = mn
			case 1:
				v = mx
			default:
				v = mn + int32(r.Uint32()%(span+1))
			}
			st.words = []uint32{uint32(v), uint32(mn), uint32(mx)}
		case "i64":
			mn := int64(r.Uint64() & 0x3fffffffffffffff)
			if r.Uint32()%20 == 0 {
				l0, l1 := w64(uint64(mn))
				st.words = []uint32{l0, l1, l0, l1, l0, l1}
				break
			}
			span := r.Uint64() & 0x3fffffffffffffff
			mx := mn + int64(span)
			var v int64
			switch r.IntN(10) {
			case 0:
				v = mn
			case 1:
				v = mx
			default:
				v = mn + int64(r.Uint64()%(span+1))
			}
			l0, l1 := w64(uint64(v))
			m0, m1 := w64(uint64(mn))
			x0, x1 := w64(uint64(mx))
			st.words = []uint32{l0, l1, m0, m1, x0, x1}
		case "i128":
			mn64 := int64(r.Uint64() & 0x3fffffffffffffff)
			if r.Uint32()%20 == 0 {
				mn := serialize.Int128From64(mn64)
				w := wI128(mn)
				st.words = append(st.words, w[:]...)
				st.words = append(st.words, w[:]...)
				st.words = append(st.words, w[:]...)
				break
			}
			span := r.Uint64() & 0x3fffffffffffffff
			mx64 := mn64 + int64(span)
			var v64 int64
			switch r.IntN(10) {
			case 0:
				v64 = mn64
			case 1:
				v64 = mx64
			default:
				v64 = mn64 + int64(r.Uint64()%(span+1))
			}
			mn := serialize.Int128From64(mn64)
			mx := serialize.Int128From64(mx64)
			v := serialize.Int128From64(v64)
			wv := wI128(v)
			wm := wI128(mn)
			wx := wI128(mx)
			st.words = append(st.words, wv[:]...)
			st.words = append(st.words, wm[:]...)
			st.words = append(st.words, wx[:]...)
		case "u128":
			w := wI128(serialize.Int128{Lo: r.Uint64(), Hi: r.Uint64()})
			st.words = append(st.words, w[:]...)
		case "fx":
			f := r.IntN(6)
			integerBits := 8 + r.IntN(8)
			min := int64(-64 - r.IntN(32))
			max := int64(64 + r.IntN(32))
			rawMin := min << uint(f)
			rawMax := max << uint(f)
			raw := rawMin + int64(r.Uint64()%uint64(rawMax-rawMin+1))
			v0, v1 := w64(uint64(raw))
			m0, m1 := w64(uint64(min))
			x0, x1 := w64(uint64(max))
			st.words = []uint32{v0, v1, uint32(integerBits), uint32(f), m0, m1, x0, x1}
		case "f128":
			f := r.IntN(8)
			integerBits := 128 - f
			min := int64(-64 - r.IntN(32))
			max := int64(64 + r.IntN(32))
			rawMin := min << uint(f)
			rawMax := max << uint(f)
			raw := rawMin + int64(r.Uint64()%uint64(rawMax-rawMin+1))
			wv := wI128(serialize.Int128From64(raw))
			m0, m1 := w64(uint64(min))
			x0, x1 := w64(uint64(max))
			st.words = []uint32{wv[0], wv[1], wv[2], wv[3], uint32(integerBits), uint32(f), m0, m1, x0, x1}
		case "cf":
			min := float32(-8)
			max := float32(8)
			res := float32(0.25)
			value := min + float32(r.IntN(65))*res
			st.words = []uint32{math.Float32bits(value), math.Float32bits(min), math.Float32bits(max), math.Float32bits(res)}
		case "ir":
			prev := int32(r.Uint32() & 0x7ffffffe)
			cur := prev + int32(1+r.Uint64()%uint64(0x7fffffff-int32(prev)))
			st.words = []uint32{uint32(prev), uint32(cur)}
		case "f":
			// finite only (STANDARD.md, "Finite values only"): a writer is never
			// handed NaN or an infinity; a mutated read meets them instead.
			u := r.Uint32()
			switch r.IntN(10) {
			case 0:
				u = r.Uint32() & 0x807fffff // a subnormal, either sign
			case 1:
				u = 0x7f7fffff // FLT_MAX
			case 2:
				u = 0xff7fffff // -FLT_MAX
			case 3:
				u = 0x80000000 // -0
			}
			if u&0x7f800000 == 0x7f800000 {
				u &^= 0x00800000
			}
			st.words = []uint32{u}
		case "d":
			u := r.Uint64()
			switch r.IntN(10) {
			case 0:
				u = r.Uint64() & 0x800fffffffffffff
			case 1:
				u = 0x7fefffffffffffff
			case 2:
				u = 0xffefffffffffffff
			case 3:
				u = 0x8000000000000000
			}
			if u&0x7ff0000000000000 == 0x7ff0000000000000 {
				u &^= 0x0010000000000000
			}
			lo, hi := w64(u)
			st.words = []uint32{lo, hi}
		case "by":
			l := 1 + r.IntN(64)
			b := make([]byte, l)
			for i := range b {
				b[i] = byte(r.Uint64() >> 56)
			}
			st.hex = hexEncode(b)
		case "s":
			// real text, well formed with no NUL (STANDARD.md string): ASCII
			// and one- to four-byte characters, so a mutated read meets every
			// UTF-8 refusal
			st.bufsize = 2 + r.IntN(100)
			l := 1 + r.IntN(st.bufsize-1)
			var b []byte
			for len(b) < l {
				c := []byte(pick(r, textPool))
				if len(b)+len(c) > l {
					c = []byte{byte('a' + r.IntN(26))}
				}
				b = append(b, c...)
			}
			st.hex = hexEncode(b)
		case "ob":
			imin := int32(r.Uint32() & 0x3fffffff)
			if r.Uint32()%20 == 0 {
				st.words = []uint32{r.Uint32() % 2, uint32(imin), uint32(imin), uint32(imin)}
				break
			}
			span := r.Uint32() & 0x3fffffff
			imax := imin + int32(span)
			var v int32
			switch r.IntN(10) {
			case 0:
				v = imin
			case 1:
				v = imax
			default:
				v = imin + int32(r.Uint32()%(span+1))
			}
			st.words = []uint32{r.Uint32() % 2, uint32(v), uint32(imin), uint32(imax)}
		}
		steps = append(steps, st)
	}
	p := program{steps: steps}
	p.expected = expectedTrace(p)
	return p
}

// textPool is the characters a generated string is made of: ASCII, a two-byte
// accent, a combining mark, CJK, Korean, Arabic, U+FFFF, an emoji and the
// largest code point.
var textPool = []string{"a", "z", "/", "\u00e9", "e\u0301", "\u7881", "\uBC14", "\u0627", "\uFFFF", "\U0001F600", "\U0010FFFF"}

// expectedTrace builds the canonical trace a successful read of the program's
// own values must produce, ending with Z, the accepted end.
func expectedTrace(p program) string {
	var toks []string
	for _, st := range p.steps {
		toks = append(toks, canonicalOf(st))
	}
	toks = append(toks, "Z")
	return strings.Join(toks, " ")
}

// refusalTok is a refusal in a trace: E and the reason as STANDARD.md spells it.
func refusalTok(err error) string {
	var r serialize.Refusal
	if errors.As(err, &r) {
		return "E:" + r.String()
	}
	return "E:" + err.Error()
}

func canonicalOf(st step) string {
	w := st.words
	switch st.op {
	case "b", "u8", "u16", "u32", "i":
		return tokU(uint64(w[0]))
	case "ir":
		return tokD(int64(int32(w[1])))
	case "b64", "u64", "i64":
		return tokH64(w[0], w[1])
	case "bl":
		if w[0] == 1 {
			return "t"
		}
		return "f"
	case "i128", "u128", "f128":
		return tokH128([4]uint32{w[0], w[1], w[2], w[3]})
	case "fx":
		return tokH64(w[0], w[1])
	case "cf":
		return tokF(w[0])
	case "f":
		return tokF(w[0])
	case "d":
		return tokDbl(w[0], w[1])
	case "by":
		return "B" + st.hex
	case "s":
		return "S" + st.hex
	case "al":
		return "A"
	case "ob":
		b := "f"
		if w[0] == 1 {
			b = "t"
		}
		return "O" + b + ":" + strconv.FormatInt(int64(int32(w[1])), 10)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Go-side write

func goWrite(s *serialize.WriteStream, st step) {
	w := st.words
	switch st.op {
	case "b":
		v := w[0]
		s.SerializeBits(&v, st.bits)
	case "b64":
		v := s64(w[0], w[1])
		s.SerializeBits64(&v, st.bits)
	case "bl":
		b := w[0] == 1
		s.SerializeBool(&b)
	case "u8":
		v := uint8(w[0])
		s.SerializeUint8(&v)
	case "u16":
		v := uint16(w[0])
		s.SerializeUint16(&v)
	case "u32":
		v := w[0]
		s.SerializeUint32(&v)
	case "u64":
		v := s64(w[0], w[1])
		s.SerializeUint64(&v)
	case "i":
		mn := int32(w[1])
		mx := int32(w[2])
		if widenRange {
			mx = widen32(mn, mx)
		}
		v := int32(w[0])
		s.SerializeInt(&v, mn, mx)
	case "i64":
		mn := int64(s64(w[2], w[3]))
		mx := int64(s64(w[4], w[5]))
		if widenRange {
			mx = widen64(mn, mx)
		}
		v := int64(s64(w[0], w[1]))
		s.SerializeInt64(&v, mn, mx)
	case "i128":
		mn := i128w(w[4], w[5], w[6], w[7])
		mx := i128w(w[8], w[9], w[10], w[11])
		if widenRange {
			mx = widen128(mn, mx)
		}
		v := i128w(w[0], w[1], w[2], w[3])
		s.SerializeInt128(&v, mn, mx)
	case "u128":
		v := u128w(w[0], w[1], w[2], w[3])
		s.SerializeUint128(&v)
	case "fx":
		v := int64(s64(w[0], w[1]))
		s.SerializeFixed64(&v, int(w[2]), int(w[3]), int64(s64(w[4], w[5])), int64(s64(w[6], w[7])))
	case "f128":
		v := i128w(w[0], w[1], w[2], w[3])
		s.SerializeFixed128(&v, int(w[4]), int(w[5]), int64(s64(w[6], w[7])), int64(s64(w[8], w[9])))
	case "cf":
		v := math.Float32frombits(w[0])
		s.SerializeCompressedFloat32(&v, math.Float32frombits(w[1]), math.Float32frombits(w[2]), math.Float32frombits(w[3]))
	case "ir":
		prev := int32(w[0])
		cur := int32(w[1])
		s.SerializeIntRelative(prev, &cur)
	case "f":
		v := math.Float32frombits(w[0])
		s.SerializeFloat32(&v)
	case "d":
		v := math.Float64frombits(s64(w[0], w[1]))
		s.SerializeFloat64(&v)
	case "by":
		s.SerializeBytes(hexDecode(st.hex))
	case "s":
		v := string(hexDecode(st.hex))
		s.SerializeString(&v, st.bufsize)
	case "al":
		s.SerializeAlign()
	case "ob":
		obj := &fuzzObj{b: w[0] == 1, v: int32(w[1]), mn: int32(w[2]), mx: int32(w[3])}
		s.SerializeObject(obj)
	}
}

type fuzzObj struct {
	b         bool
	v, mn, mx int32
}

func (o *fuzzObj) Serialize(s serialize.Stream) error {
	if err := s.SerializeBool(&o.b); err != nil {
		return err
	}
	return s.SerializeInt(&o.v, o.mn, o.mx)
}

// widening: double the span so the wire range gains at least one bit.

func widen32(mn, mx int32) int32 {
	if mn == mx {
		return mx
	}
	span := uint64(uint32(mx)) - uint64(uint32(mn))
	return int32(uint32(mn) + uint32(2*span))
}

func widen64(mn, mx int64) int64 {
	if mn == mx {
		return mx
	}
	span := uint64(mx) - uint64(mn)
	return int64(uint64(mn) + 2*span)
}

func widen128(mn, mx serialize.Int128) serialize.Int128 {
	if mn.Cmp(mx) == 0 {
		return mx
	}
	span := mx.Uint128().Sub(mn.Uint128())
	return span.Add(span).Add(mn.Uint128()).Int128()
}

// ---------------------------------------------------------------------------
// Go-side read (trace)

func goRead(data []byte, p program) string {
	s := serialize.NewReadStream(data)
	var toks []string
	for _, st := range p.steps {
		tok, ok := readOne(s, st)
		if !ok {
			toks = append(toks, refusalTok(s.Err()))
			return strings.Join(toks, " ")
		}
		toks = append(toks, tok)
	}
	if err := s.SerializeEnd(); err != nil {
		toks = append(toks, refusalTok(err))
	} else {
		toks = append(toks, "Z")
	}
	return strings.Join(toks, " ")
}

func readOne(s *serialize.ReadStream, st step) (string, bool) {
	w := st.words
	var err error
	switch st.op {
	case "b":
		var v uint32
		err = s.SerializeBits(&v, st.bits)
		return tokU(uint64(v)), err == nil
	case "b64":
		var v uint64
		err = s.SerializeBits64(&v, st.bits)
		l0, l1 := w64(v)
		return tokH64(l0, l1), err == nil
	case "bl":
		var b bool
		err = s.SerializeBool(&b)
		if err != nil {
			return "", false
		}
		if b {
			return "t", true
		}
		return "f", true
	case "u8":
		var v uint8
		err = s.SerializeUint8(&v)
		return tokU(uint64(v)), err == nil
	case "u16":
		var v uint16
		err = s.SerializeUint16(&v)
		return tokU(uint64(v)), err == nil
	case "u32":
		var v uint32
		err = s.SerializeUint32(&v)
		return tokU(uint64(v)), err == nil
	case "u64":
		var v uint64
		err = s.SerializeUint64(&v)
		l0, l1 := w64(v)
		return tokH64(l0, l1), err == nil
	case "i":
		var v int32
		err = s.SerializeInt(&v, int32(w[1]), int32(w[2]))
		return tokD(int64(v)), err == nil
	case "i64":
		var v int64
		err = s.SerializeInt64(&v, int64(s64(w[2], w[3])), int64(s64(w[4], w[5])))
		l0, l1 := w64(uint64(v))
		return tokH64(l0, l1), err == nil
	case "i128":
		v := serialize.Int128{}
		mn := i128w(w[4], w[5], w[6], w[7])
		mx := i128w(w[8], w[9], w[10], w[11])
		err = s.SerializeInt128(&v, mn, mx)
		wv := wI128(v)
		return tokH128(wv), err == nil
	case "u128":
		v := serialize.Uint128{}
		err = s.SerializeUint128(&v)
		wv := wI128(v.Int128())
		return tokH128(wv), err == nil
	case "fx":
		var v int64
		err = s.SerializeFixed64(&v, int(w[2]), int(w[3]), int64(s64(w[4], w[5])), int64(s64(w[6], w[7])))
		l0, l1 := w64(uint64(v))
		return tokH64(l0, l1), err == nil
	case "f128":
		v := serialize.Int128{}
		err = s.SerializeFixed128(&v, int(w[4]), int(w[5]), int64(s64(w[6], w[7])), int64(s64(w[8], w[9])))
		wv := wI128(v)
		return tokH128(wv), err == nil
	case "cf":
		var v float32
		err = s.SerializeCompressedFloat32(&v, math.Float32frombits(w[1]), math.Float32frombits(w[2]), math.Float32frombits(w[3]))
		return tokF(math.Float32bits(v)), err == nil
	case "ir":
		var cur int32
		err = s.SerializeIntRelative(int32(w[0]), &cur)
		return tokD(int64(cur)), err == nil
	case "f":
		var v float32
		err = s.SerializeFloat32(&v)
		return tokF(math.Float32bits(v)), err == nil
	case "d":
		var v float64
		err = s.SerializeFloat64(&v)
		l0, l1 := w64(math.Float64bits(v))
		return tokDbl(l0, l1), err == nil
	case "by":
		dst := make([]byte, len(hexDecode(st.hex)))
		err = s.SerializeBytes(dst)
		return "B" + hexEncode(dst), err == nil
	case "s":
		v := ""
		err = s.SerializeString(&v, st.bufsize)
		return "S" + hexEncode([]byte(v)), err == nil
	case "al":
		err = s.SerializeAlign()
		return "A", err == nil
	case "ob":
		obj := &fuzzObj{mn: int32(w[2]), mx: int32(w[3])}
		err = s.SerializeObject(obj)
		b := "f"
		if obj.b {
			b = "t"
		}
		return "O" + b + ":" + strconv.FormatInt(int64(obj.v), 10), err == nil
	}
	return "", true
}

// ---------------------------------------------------------------------------
// mutation

func mutateBytes(data []byte, recipe []string) []byte {
	kind := recipe[0]
	switch kind {
	case "F":
		bi := atoi(recipe[1])
		bit := atoi(recipe[2])
		out := append([]byte(nil), data...)
		if bi < len(out) {
			out[bi] ^= 1 << uint(bit)
		}
		return out
	case "T":
		k := atoi(recipe[1])
		if k > len(data) {
			k = len(data)
		}
		return append([]byte(nil), data[:k]...)
	default: // G
		n := atoi(recipe[1])
		out := append([]byte(nil), data...)
		out = append(out, make([]byte, n)...)
		return out
	}
}

func atoi(s string) int {
	v, _ := strconv.Atoi(s)
	return v
}

// ---------------------------------------------------------------------------
// batching and running

func writeGoProgram(p program) []byte {
	buf := make([]byte, bufferSize)
	s := serialize.NewWriteStream(buf)
	for _, st := range p.steps {
		goWrite(s, st)
		if s.Err() != nil {
			break
		}
	}
	s.Flush()
	return s.Data()
}

// runBatch builds a temp run directory with the unit and driver, runs the
// interpreter once over the batch text and returns the parsed output lines.
func runBatch(t *testing.T, repoRoot string, batchText string) []string {
	t.Helper()
	dir := t.TempDir()
	src, err := os.ReadDir(filepath.Join(repoRoot, "src"))
	if err != nil {
		t.Fatalf("read src: %v", err)
	}
	for _, e := range src {
		b, err := os.ReadFile(filepath.Join(repoRoot, "src", e.Name()))
		if err != nil {
			t.Fatalf("read src file: %v", err)
		}
		if err := os.WriteFile(filepath.Join(dir, e.Name()), b, 0o644); err != nil {
			t.Fatalf("write src file: %v", err)
		}
	}
	drv, err := os.ReadFile(filepath.Join(repoRoot, "fuzz", "driver.luau"))
	if err != nil {
		t.Fatalf("read driver: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "driver.luau"), drv, 0o644); err != nil {
		t.Fatalf("write driver: %v", err)
	}
	in := "return [====[\n" + batchText + "\n]====]\n"
	if err := os.WriteFile(filepath.Join(dir, "inputs.luau"), []byte(in), 0o644); err != nil {
		t.Fatalf("write inputs: %v", err)
	}
	luau := filepath.Join(repoRoot, "dist", "luau-0.741", "luau")
	cmd := exec.Command(luau, "driver.luau")
	cmd.Dir = dir
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Run(); err != nil {
		t.Fatalf("interpreter failed: %v\n%s", err, out.String())
	}
	text := out.String()
	text = strings.TrimSpace(text)
	if text == "" {
		t.Fatal("driver produced no output")
	}
	return strings.Split(text, "\n")
}

func buildBatchText(programs []program) string {
	var sb strings.Builder
	for _, p := range programs {
		sb.WriteString("P\n")
		for _, st := range p.steps {
			sb.WriteString(st.text())
		}
		if p.mutate != nil {
			sb.WriteString("M " + strings.Join(p.mutate, " ") + "\n")
		}
		sb.WriteString("E\n")
	}
	return sb.String()
}

func (st step) text() string {
	var sb strings.Builder
	sb.WriteString(st.op)
	if st.op == "by" || st.op == "s" {
		if st.op == "s" {
			sb.WriteString(" " + strconv.Itoa(st.bufsize))
		}
		sb.WriteString(" " + st.hex)
	} else {
		for _, v := range st.words {
			sb.WriteString(" " + strconv.FormatUint(uint64(v), 10))
		}
		if st.op == "b" || st.op == "b64" {
			sb.WriteString(" " + strconv.Itoa(st.bits))
		}
	}
	sb.WriteString("\n")
	return sb.String()
}

func verifyBatch(t *testing.T, repoRoot string, programs []program) {
	t.Helper()
	batchText := buildBatchText(programs)
	lines := runBatch(t, repoRoot, batchText)
	li := 0
	for idx, p := range programs {
		n := 2
		if p.mutate != nil {
			n = 3
		}
		var wants []string
		for j := 0; j < n && li < len(lines); j++ {
			wants = append(wants, lines[li])
			li++
		}
		if len(wants) < n {
			t.Errorf("program %d: driver output truncated (got %d lines, want %d)", idx, len(wants), n)
			continue
		}
		var wline, rline, mline string
		for _, l := range wants {
			switch {
			case strings.HasPrefix(l, "WE "):
				wline = l
			case strings.HasPrefix(l, "W "):
				wline = l
			case strings.HasPrefix(l, "R "):
				rline = l
			case strings.HasPrefix(l, "M "):
				mline = l
			}
		}
		bytesA := writeGoProgram(p)
		if strings.HasPrefix(wline, "WE ") {
			t.Errorf("program %d write refused unexpectedly (driver kind=%s)", idx, strings.TrimPrefix(wline, "WE "))
			continue
		}
		wantHex := strings.TrimPrefix(wline, "W ")
		if wantHex != hexEncode(bytesA) {
			t.Errorf("program %d write mismatch\n  go: %s\n  luau: %s", idx, hexEncode(bytesA), wantHex)
			continue
		}
		exp := p.expected
		traceG := goRead(bytesA, p)
		if traceG != exp {
			t.Errorf("program %d: go read-back != expected\n  expected: %s\n  go:      %s", idx, exp, traceG)
		}
		traceL := strings.TrimPrefix(rline, "R ")
		if traceL != traceG {
			t.Errorf("program %d read-back mismatch\n  go:   %s\n  luau: %s", idx, traceG, traceL)
		}
		if p.mutate != nil {
			mut := mutateBytes(bytesA, p.mutate)
			mtraceG := goRead(mut, p)
			mtraceL := strings.TrimPrefix(mline, "M ")
			if mtraceL != mtraceG {
				t.Errorf("program %d mutated-read mismatch\n  go:   %s\n  luau: %s\n  recipe: %v", idx, mtraceG, mtraceL, p.mutate)
			}
		}
	}
}

func TestDifferentialAgainstSerializeGo(t *testing.T) {
	r := rand.New(rand.NewPCG(20261017, 0x5eed))
	repoRoot, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoRoot = filepath.Dir(repoRoot)
	programs := make([]program, 0, numPrograms)
	for i := 0; i < numPrograms; i++ {
		p := genProgram(r)
		if i%4 == 0 {
			a := writeGoProgram(p)
			if len(a) > 0 {
				switch r.IntN(3) {
				case 0:
					bi := r.IntN(len(a))
					bit := r.IntN(8)
					p.mutate = []string{"F", strconv.Itoa(bi), strconv.Itoa(bit)}
				case 1:
					k := r.IntN(len(a) + 1)
					p.mutate = []string{"T", strconv.Itoa(k)}
				default:
					n := 1 + r.IntN(8)
					p.mutate = []string{"G", strconv.Itoa(n)}
				}
			}
		}
		programs = append(programs, p)
	}
	mutated := 0
	for _, p := range programs {
		if p.mutate != nil {
			mutated++
		}
	}
	t.Logf("differential: %d programs, %d mutated", len(programs), mutated)
	for b := 0; b < numPrograms/batchSize; b++ {
		start := b * batchSize
		verifyBatch(t, repoRoot, programs[start:start+batchSize])
	}
}

func TestDifferentialNegativeControl(t *testing.T) {
	widenRange = true
	defer func() { widenRange = false }()
	r := rand.New(rand.NewPCG(99, 42))
	repoRoot, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	repoRoot = filepath.Dir(repoRoot)
	var programs []program
	// negative control: int-only programs, spans chosen as 2^k-1 so the
	// widened range is guaranteed one bit wider.
	for i := 0; i < 200; i++ {
		mn := int32(r.Uint32() & 0x3fffffff)
		k := 1 + r.IntN(20)
		span := (int64(1) << uint(k)) - 1
		mx := mn + int32(span)
		v := mn + int32(r.Uint64()%uint64(span+1))
		st := step{op: "i", words: []uint32{uint32(v), uint32(mn), uint32(mx)}}
		p := program{steps: []step{st}}
		p.expected = expectedTrace(p)
		programs = append(programs, p)
	}
	detected := 0
	// run one batch with the widening flag: every program must diverge
	// because the Go side writes a one-bit-wider range.
	batchText := buildBatchText(programs)
	lines := runBatch(t, repoRoot, batchText)
	li := 0
	for _, p := range programs {
		var wants []string
		for li < len(lines) {
			l := lines[li]
			if strings.HasPrefix(l, "W ") || strings.HasPrefix(l, "WE ") || strings.HasPrefix(l, "R ") || strings.HasPrefix(l, "M ") {
				wants = append(wants, l)
				li++
			} else {
				break
			}
		}
		var wline string
		for _, l := range wants {
			if strings.HasPrefix(l, "W ") {
				wline = l
			}
		}
		bytesA := writeGoProgram(p)
		if wline != "" && strings.TrimPrefix(wline, "W ") != hexEncode(bytesA) {
			detected++
		}
	}
	if detected == 0 {
		t.Error("negative control: no divergence detected (widenRange did not change the wire)")
	}
}
