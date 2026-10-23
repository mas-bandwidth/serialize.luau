package main

import (
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
