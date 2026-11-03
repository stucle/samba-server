package main

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
	"unicode"
)

// Same expression as smbctl's valid_name. Both layers validate: smbctl is also run by hand, and this service must not rely on a downstream check either.
var nameRe = regexp.MustCompile(`^[a-z0-9_-]+$`)

// validName rejects anything that could be read as a flag by adduser/addgroup or as syntax by smb.conf. max is:
// 32 for users and groups,
// 26 for sharepoints (the derived sp_<name>_r group name has to stay within 32 itself).
func validName(s string, max int) error {
	switch {
	case s == "":
		return errors.New("must not be empty")
	case len(s) > max:
		return fmt.Errorf("must be at most %d characters", max)
	case strings.HasPrefix(s, "-"):
		return errors.New("must not start with '-'")
	case !nameRe.MatchString(s):
		return errors.New("must match ^[a-z0-9_-]+$")
	}
	return nil
}

func hasControl(s string) bool {
	for _, r := range s {
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}

// sanitize makes command output safe to put in a JSON audit line and in an HTTP response: one line, no control characters, bounded length.
func sanitize(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\t':
			return ' '
		case unicode.IsControl(r):
			return -1
		}
		return r
	}, s)
	s = strings.Join(strings.Fields(s), " ")
	const max = 2000
	if len(s) > max {
		return s[:max] + " …(truncated)"
	}
	return s
}
