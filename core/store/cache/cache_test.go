package cache

import (
	"testing"
	"time"
)

func TestCacheGetPutAndExpiry(t *testing.T) {
	now := time.Unix(0, 0)
	c := New[string, int](4, time.Minute)
	c.now = func() time.Time { return now }

	c.Put("a", 1)
	if v, ok := c.Get("a"); !ok || v != 1 {
		t.Fatalf("Get(a) = %d, %v; want 1, true", v, ok)
	}
	now = now.Add(2 * time.Minute)
	if _, ok := c.Get("a"); ok {
		t.Fatal("Get(a) after TTL = present; want expired")
	}
}

func TestCacheEvictsLRU(t *testing.T) {
	c := New[string, int](2, 0)
	c.Put("a", 1)
	c.Put("b", 2)
	c.Get("a") // a is now most-recently used
	c.Put("c", 3)

	if _, ok := c.Get("b"); ok {
		t.Fatal("b should have been evicted")
	}
	if c.Len() != 2 {
		t.Fatalf("Len = %d, want 2", c.Len())
	}
}
