package nodeagent

import "testing"

func TestValidCAHash(t *testing.T) {
	valid := "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	if !validCAHash(valid) {
		t.Fatal("expected a valid CA hash")
	}
	for _, invalid := range []string{"", "sha256:abc", "sha512:" + valid, "sha256:ABCDEF"} {
		if validCAHash(invalid) {
			t.Fatalf("accepted invalid hash %q", invalid)
		}
	}
}
