// Command luaurun is serialize.luau's test runner (DESIGN.md, (i) THE RUNNER).
//
// The luau CLI has no io library, so a Luau test can neither open a file nor
// read stdin: inputs go IN as source and results come OUT on stdout. For each
// test directory test/<name>/ the runner builds a run directory
// build/run/<name>/:
//
//	build/run/<name>/          the working directory the interpreter runs in
//	build/run/<name>/<plant>   every file of test/<name>/plant/, planted one
//	                           level above the unit (the loading-is-closed tests)
//	build/run/<name>/src/      THE UNIT: a copy of src/*.luau, the .luau files
//	                           of test/<name>/, inputs.luau (every
//	                           conformance/*.txt as a string), control.luau
//	                           (the control this run is, empty here) and
//	                           _luaurun.luau, the driver
//
// The driver requires each *_test.luau module (a table of functions), runs
// every function named Test<Name> in sorted order and prints RUN Test<Name>,
// then --- PASS Test<Name> or --- FAIL Test<Name> with the raise indented on
// the next line. The runner passes stdout through and exits nonzero on a FAIL,
// on an interpreter that exits nonzero, on a directory that runs no test, and
// on a missing or empty test/<name>/, naming it: never a skip.
//
// Usage: luaurun -root <repo> [name...]; no names runs every test/*/.
// The interpreter is $LUAU, else <repo>/dist/luau-0.741/luau.
//
// THE NEGATIVE CONTROLS (STANDARD.md, "A gate nobody has seen go red"):
// luaurun -root <repo> -controls runs every control of
// tools/controls/controls.tsv. Each builds build/run/control-<name>/ as the
// unit of test/conformance/ (its conformance_test.luau alone), with ONE
// refusal rule deleted from a copy of one src file (a needle that must occur
// exactly once, else the control is red: a control that has quietly stopped
// sabotaging anything is worse than none), or, for unknown-operation, with
// conformance-controls/unknown-operation.txt added to the corpus. control.luau
// carries the control's name and its conformance-controls/<name>.expected
// list, and the conformance test passes only when the vectors that fail are
// exactly that list.
//
// Standard library only; no time, no sockets, no network.
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const luauVersion = "0.741"

func main() {
	root := flag.String("root", ".", "the repository root")
	controls := flag.Bool("controls", false, "run the negative controls of tools/controls/controls.tsv")
	flag.Parse()
	if *controls {
		os.Exit(runControls(*root, os.Stdout, os.Stderr))
	}
	os.Exit(run(*root, flag.Args(), os.Stdout, os.Stderr))
}

// runSpec is how one run directory is built: the test files to drive, and, for a
// control, the control's name, its expected list, a source patch and an
// extra corpus file.
type runSpec struct {
	label    string
	dir      string   // build/run/<dir>
	testDir  string   // test/<name>, whose .luau files join the unit
	tests    []string // the *_test.luau files the driver runs
	control  string   // the control's name, empty for an ordinary run
	expected string   // the control's expected list, verbatim
	patches  []patch
	extra    map[string][]byte // extra corpus files, by base name
}

// patch replaces needle, which must occur exactly once, in a copy of file.
type patch struct {
	file, needle, replacement string
}

func run(root string, names []string, stdout, stderr io.Writer) int {
	luau, why := interpreter(root)
	if luau == "" {
		fmt.Fprintf(stderr, "luaurun: the Luau interpreter does not resolve: %s\n", why)
		return 1
	}
	if len(names) == 0 {
		entries, err := os.ReadDir(filepath.Join(root, "test"))
		if err != nil {
			fmt.Fprintf(stderr, "luaurun: test/ is missing: %v\n", err)
			return 1
		}
		for _, e := range entries {
			if e.IsDir() {
				names = append(names, e.Name())
			}
		}
		if len(names) == 0 {
			fmt.Fprintf(stderr, "luaurun: test/ has no test directories\n")
			return 1
		}
	}
	failed := 0
	for _, name := range names {
		if !runDir(root, luau, name, stdout, stderr) {
			failed++
		}
	}
	if failed != 0 {
		fmt.Fprintf(stdout, "FAIL %d of %d test directories\n", failed, len(names))
		return 1
	}
	fmt.Fprintf(stdout, "ok %d test directories\n", len(names))
	return 0
}

// interpreter resolves $LUAU, else the pinned dist/luau-0.741/luau.
func interpreter(root string) (string, string) {
	if p := os.Getenv("LUAU"); p != "" {
		if lp, err := exec.LookPath(p); err == nil {
			return lp, ""
		}
		return "", fmt.Sprintf("$LUAU=%s does not resolve; run make dist-luau (or unset LUAU)", p)
	}
	p := filepath.Join(root, "dist", "luau-"+luauVersion, "luau")
	if _, err := os.Stat(p); err != nil {
		return "", fmt.Sprintf("the pinned luau is not at %s; run make dist-luau", p)
	}
	return p, ""
}

var validName = regexp.MustCompile(`^[a-z0-9_]+$`)

// runDir builds build/run/<name>/ and runs its tests, reporting success.
func runDir(root, luau, name string, stdout, stderr io.Writer) bool {
	label := "test/" + name + "/"
	if !validName.MatchString(name) {
		fmt.Fprintf(stdout, "FAIL %s: not a test directory name ([a-z0-9_]+)\n", label)
		return false
	}
	testDir := filepath.Join(root, "test", name)
	if st, err := os.Stat(testDir); err != nil || !st.IsDir() {
		fmt.Fprintf(stdout, "FAIL %s is missing\n", label)
		return false
	}
	tests, _ := filepath.Glob(filepath.Join(testDir, "*_test.luau"))
	sort.Strings(tests)
	if len(tests) == 0 {
		fmt.Fprintf(stdout, "FAIL %s is empty: no *_test.luau files\n", label)
		return false
	}
	return runUnit(root, luau, runSpec{label: label, dir: name, testDir: testDir, tests: tests}, stdout, stderr)
}

// runUnit builds build/run/<u.dir>/ and runs its tests, reporting success.
func runUnit(root, luau string, u runSpec, stdout, stderr io.Writer) bool {
	label, testDir, tests := u.label, u.testDir, u.tests
	runDir := filepath.Join(root, "build", "run", u.dir)
	unit := filepath.Join(runDir, "src")
	if err := os.RemoveAll(runDir); err != nil {
		fmt.Fprintf(stderr, "luaurun: %v\n", err)
		return false
	}
	if err := os.MkdirAll(unit, 0o755); err != nil {
		fmt.Fprintf(stderr, "luaurun: %v\n", err)
		return false
	}
	srcs, _ := filepath.Glob(filepath.Join(root, "src", "*.luau"))
	helpers, _ := filepath.Glob(filepath.Join(testDir, "*.luau"))
	for _, f := range append(srcs, helpers...) {
		if err := copyFile(f, filepath.Join(unit, filepath.Base(f))); err != nil {
			fmt.Fprintf(stderr, "luaurun: %v\n", err)
			return false
		}
	}
	plants, _ := filepath.Glob(filepath.Join(testDir, "plant", "*"))
	for _, f := range plants {
		if err := copyFile(f, filepath.Join(runDir, filepath.Base(f))); err != nil {
			fmt.Fprintf(stderr, "luaurun: %v\n", err)
			return false
		}
	}
	for _, p := range u.patches {
		target := filepath.Join(unit, p.file)
		b, err := os.ReadFile(target)
		if err != nil {
			fmt.Fprintf(stdout, "FAIL %s: the patched file %s is not in the unit\n", label, p.file)
			return false
		}
		if n := strings.Count(string(b), p.needle); n != 1 {
			fmt.Fprintf(stdout, "FAIL %s: the needle occurs %d times in %s, not once: %q\n", label, n, p.file, p.needle)
			return false
		}
		b = []byte(strings.Replace(string(b), p.needle, p.replacement, 1))
		if err := os.WriteFile(target, b, 0o644); err != nil {
			fmt.Fprintf(stderr, "luaurun: %v\n", err)
			return false
		}
	}
	inputs, err := inputsModule(filepath.Join(root, "conformance"), u.extra)
	if err != nil {
		fmt.Fprintf(stderr, "luaurun: %v\n", err)
		return false
	}
	if err := os.WriteFile(filepath.Join(unit, "inputs.luau"), inputs, 0o644); err != nil {
		fmt.Fprintf(stderr, "luaurun: %v\n", err)
		return false
	}
	if err := os.WriteFile(filepath.Join(unit, "control.luau"), controlModule(u.control, u.expected), 0o644); err != nil {
		fmt.Fprintf(stderr, "luaurun: %v\n", err)
		return false
	}
	if err := os.WriteFile(filepath.Join(unit, "_luaurun.luau"), driver(tests), 0o644); err != nil {
		fmt.Fprintf(stderr, "luaurun: %v\n", err)
		return false
	}

	cmd := exec.Command(luau, filepath.Join("src", "_luaurun.luau"))
	cmd.Dir = runDir
	var out bytes.Buffer
	cmd.Stdout = io.MultiWriter(stdout, &out)
	cmd.Stderr = stderr
	runErr := cmd.Run()

	runs, passes, fails := 0, 0, 0
	for _, line := range strings.Split(out.String(), "\n") {
		switch {
		case strings.HasPrefix(line, "RUN Test"):
			runs++
		case strings.HasPrefix(line, "--- PASS Test"):
			passes++
		case strings.HasPrefix(line, "--- FAIL Test"):
			fails++
		}
	}
	switch {
	case runErr != nil:
		fmt.Fprintf(stdout, "FAIL %s: luau exited: %v\n", label, runErr)
		return false
	case runs == 0:
		fmt.Fprintf(stdout, "FAIL %s ran no Test functions\n", label)
		return false
	case fails != 0 || passes != runs:
		fmt.Fprintf(stdout, "FAIL %s: %d of %d tests failed\n", label, runs-passes, runs)
		return false
	}
	fmt.Fprintf(stdout, "ok %s %d passed\n", label, passes)
	return true
}

func copyFile(from, to string) error {
	b, err := os.ReadFile(from)
	if err != nil {
		return err
	}
	return os.WriteFile(to, b, 0o644)
}

// inputsModule is the Luau source of inputs.luau: a frozen table mapping each
// conformance file's base name (bool for conformance/bool.txt) to its text,
// plus any extra files a control adds.
func inputsModule(dir string, extra map[string][]byte) ([]byte, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.txt"))
	if err != nil {
		return nil, err
	}
	texts := map[string][]byte{}
	for _, f := range files {
		text, err := os.ReadFile(f)
		if err != nil {
			return nil, err
		}
		texts[strings.TrimSuffix(filepath.Base(f), ".txt")] = text
	}
	for name, text := range extra {
		if _, clash := texts[name]; clash {
			return nil, fmt.Errorf("the control's extra corpus file %s.txt is already in conformance/", name)
		}
		texts[name] = text
	}
	names := make([]string, 0, len(texts))
	for name := range texts {
		names = append(names, name)
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString("--!strict\n-- inputs.luau, written by tools/luaurun (DESIGN.md (i)): conformance/*.txt as strings\nreturn table.freeze({\n")
	for _, name := range names {
		fmt.Fprintf(&b, "\t[%s] = %s,\n", luauString([]byte(name)), luauString(texts[name]))
	}
	b.WriteString("})\n")
	return []byte(b.String()), nil
}

// luauString is text as a Luau string literal.
func luauString(text []byte) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, c := range text {
		switch {
		case c == '\\' || c == '"':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString("\\n")
		case c >= 0x20 && c < 0x7f:
			b.WriteByte(c)
		default:
			fmt.Fprintf(&b, "\\x%02x", c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// controlModule is the Luau source of control.luau: the control this run is
// (an empty name for an ordinary run) and its expected list, verbatim.
func controlModule(name, expected string) []byte {
	return []byte("--!strict\n-- control.luau, written by tools/luaurun: the negative control this run is, if any\nreturn table.freeze({ name = " +
		luauString([]byte(name)) + ", expected = " + luauString([]byte(expected)) + " })\n")
}

// runControls runs every control of tools/controls/controls.tsv: one line per
// patch (a control of several lines patches each), four tab-separated fields, name, src file, needle and replacement
// (\n and \t in a needle or replacement are a newline and a tab, so a needle
// can span lines; a file of "-" and empty needle and replacement for
// unknown-operation, which
// patches nothing and adds conformance-controls/unknown-operation.txt to the
// corpus instead). Lines starting with # are comments.
func runControls(root string, stdout, stderr io.Writer) int {
	luau, why := interpreter(root)
	if luau == "" {
		fmt.Fprintf(stderr, "luaurun: the Luau interpreter does not resolve: %s\n", why)
		return 1
	}
	table, err := os.ReadFile(filepath.Join(root, "tools", "controls", "controls.tsv"))
	if err != nil {
		fmt.Fprintf(stdout, "FAIL controls: %v\n", err)
		return 1
	}
	testDir := filepath.Join(root, "test", "conformance")
	tests := []string{filepath.Join(testDir, "conformance_test.luau")}
	// A control is every row carrying its name, in order: a rule this port
	// keeps in more than one place is deleted from each of them, one needle a
	// row.
	var order []string
	rows := map[string][][]string{}
	failed := 0
	for i, line := range strings.Split(string(table), "\n") {
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 4 || !validControl.MatchString(fields[0]) {
			fmt.Fprintf(stdout, "FAIL controls.tsv:%d: want name<TAB>file<TAB>needle<TAB>replacement\n", i+1)
			failed++
			continue
		}
		if _, seen := rows[fields[0]]; !seen {
			order = append(order, fields[0])
		}
		rows[fields[0]] = append(rows[fields[0]], fields)
	}
	unescape := strings.NewReplacer(`\n`, "\n", `\t`, "\t")
	ran := 0
	for _, name := range order {
		u := runSpec{label: "control " + name, dir: "control-" + name, testDir: testDir, tests: tests, control: name}
		if name == "unknown-operation" {
			text, err := os.ReadFile(filepath.Join(root, "conformance-controls", "unknown-operation.txt"))
			if err != nil {
				fmt.Fprintf(stdout, "FAIL control %s: %v\n", name, err)
				failed++
				continue
			}
			u.extra = map[string][]byte{"unknown-operation": text}
			var names []string
			for _, l := range strings.Split(string(text), "\n") {
				if strings.HasPrefix(l, "name ") {
					names = append(names, strings.TrimPrefix(l, "name "))
				}
			}
			u.expected = strings.Join(names, "\n") + "\n"
		} else {
			expected, err := os.ReadFile(filepath.Join(root, "conformance-controls", name+".expected"))
			if err != nil {
				fmt.Fprintf(stdout, "FAIL control %s: %v\n", name, err)
				failed++
				continue
			}
			u.expected = string(expected)
			for _, f := range rows[name] {
				u.patches = append(u.patches, patch{file: f[1], needle: unescape.Replace(f[2]), replacement: unescape.Replace(f[3])})
			}
		}
		ran++
		if !runUnit(root, luau, u, stdout, stderr) {
			failed++
		}
	}
	if ran == 0 {
		fmt.Fprintf(stdout, "FAIL controls: controls.tsv names no control\n")
		return 1
	}
	if failed != 0 {
		fmt.Fprintf(stdout, "FAIL %d of %d negative controls\n", failed, ran)
		return 1
	}
	fmt.Fprintf(stdout, "ok %d negative controls\n", ran)
	return 0
}

var validControl = regexp.MustCompile(`^[a-z0-9-]+$`)

// driver is the Luau source of _luaurun.luau: it requires every test module
// by a literal ./ path and runs its Test functions in sorted order.
func driver(tests []string) []byte {
	var b strings.Builder
	b.WriteString("-- _luaurun.luau, written by tools/luaurun (DESIGN.md (i))\nlocal modules = {\n")
	for _, t := range tests {
		mod := strings.TrimSuffix(filepath.Base(t), ".luau")
		fmt.Fprintf(&b, "\t{ %q, require(\"./%s\") },\n", mod, mod)
	}
	b.WriteString(`}
for _, entry in modules do
	local mod = entry[2]
	if type(mod) ~= "table" then
		error("luaurun: " .. entry[1] .. ".luau does not return a table of Test functions")
	end
	local names = {}
	for name, fn in mod do
		if type(name) == "string" and string.match(name, "^Test") and type(fn) == "function" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		print("RUN " .. name)
		local ok, err = pcall(mod[name])
		if ok then
			print("--- PASS " .. name)
		else
			print("--- FAIL " .. name)
			print("    " .. string.gsub(tostring(err), "\n", "\n    "))
		end
	end
end
`)
	return []byte(b.String())
}
