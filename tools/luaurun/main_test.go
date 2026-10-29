package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The corpus root override, a unit test: unset and empty are the repository
// root, a named directory is read in place of the vendored copy. The named
// root is a fixture inside this package, testdata/corpus/.
func TestCorpusRootOverride(t *testing.T) {
	if got := corpusRoot("/repo", ""); got != "/repo" {
		t.Fatalf("an unset or empty SERIALIZE_CORPUS_DIR is the repository root, got %q", got)
	}
	if got := corpusRoot("/repo", "testdata/corpus"); got != "testdata/corpus" {
		t.Fatalf("SERIALIZE_CORPUS_DIR names the corpus root, got %q", got)
	}

	t.Setenv("SERIALIZE_CORPUS_DIR", "testdata/corpus")
	inputs, err := inputsModule(filepath.Join(corpusDir("/repo"), "conformance"), nil)
	if err != nil {
		t.Fatalf("the fixture corpus root does not read: %v", err)
	}
	if !strings.Contains(string(inputs), "override-true") {
		t.Fatalf("inputs.luau does not carry the fixture root's vector:\n%s", inputs)
	}

	t.Setenv("SERIALIZE_CORPUS_DIR", "")
	if got := corpusDir("/repo"); got != "/repo" {
		t.Fatalf("an empty SERIALIZE_CORPUS_DIR reads the vendored copy, got %q", got)
	}
}

// The extra corpus directories: test/regress/ is always read, then each
// directory of SERIALIZE_CORPUS_EXTRA_DIR; a controls build never reads them
// (runUnit asks only when u.control is empty); a name in two places is refused
// and a named directory that is missing is an error.
func TestExtraCorpusDirs(t *testing.T) {
	root := t.TempDir()
	reg := filepath.Join(root, "test", "regress")
	extra := t.TempDir()
	for dir, name := range map[string]string{reg: "regress.txt", extra: "generated.txt"} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("SERIALIZE_CORPUS_EXTRA_DIR", extra)
	got, err := withExtraDirs(root, nil)
	if err != nil || len(got) != 2 || got["regress"] == nil || got["generated"] == nil {
		t.Fatalf("regress and the named extra directory both join, got %v, %v", got, err)
	}
	t.Setenv("SERIALIZE_CORPUS_EXTRA_DIR", filepath.Join(root, "missing"))
	if _, err := withExtraDirs(root, nil); err == nil {
		t.Fatal("a missing named extra directory must be an error")
	}
	t.Setenv("SERIALIZE_CORPUS_EXTRA_DIR", reg)
	if _, err := withExtraDirs(root, nil); err == nil {
		t.Fatal("a file named twice must be refused")
	}
	t.Setenv("SERIALIZE_CORPUS_EXTRA_DIR", "")
	if got, err := withExtraDirs(t.TempDir(), nil); err != nil || len(got) != 0 {
		t.Fatalf("no regress directory and no variable adds nothing, got %v, %v", got, err)
	}
}
