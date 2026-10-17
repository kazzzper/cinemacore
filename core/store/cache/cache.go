// Package cache is a small thread-safe LRU with per-entry TTL, used for signed
// response caching. No external dependencies.
package cache

import (
	"container/list"
	"sync"
	"time"
)

type entry[K comparable, V any] struct {
	key K
	val V
	exp time.Time
}

// Cache is a fixed-capacity LRU keyed by K.
type Cache[K comparable, V any] struct {
	mu   sync.Mutex
	size int
	ttl  time.Duration
	ll   *list.List
	m    map[K]*list.Element
	now  func() time.Time
}

// New returns a cache holding at most size entries, each valid for ttl.
func New[K comparable, V any](size int, ttl time.Duration) *Cache[K, V] {
	if size < 1 {
		size = 1
	}
	return &Cache[K, V]{size: size, ttl: ttl, ll: list.New(), m: make(map[K]*list.Element), now: time.Now}
}

// Get returns the value for k if present and unexpired.
func (c *Cache[K, V]) Get(k K) (V, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	var zero V
	el, ok := c.m[k]
	if !ok {
		return zero, false
	}
	e := el.Value.(*entry[K, V])
	if c.ttl > 0 && c.now().After(e.exp) {
		c.removeElement(el)
		return zero, false
	}
	c.ll.MoveToFront(el)
	return e.val, true
}

// Put inserts or refreshes k.
func (c *Cache[K, V]) Put(k K, v V) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if el, ok := c.m[k]; ok {
		e := el.Value.(*entry[K, V])
		e.val = v
		e.exp = c.now().Add(c.ttl)
		c.ll.MoveToFront(el)
		return
	}
	el := c.ll.PushFront(&entry[K, V]{key: k, val: v, exp: c.now().Add(c.ttl)})
	c.m[k] = el
	for c.ll.Len() > c.size {
		if oldest := c.ll.Back(); oldest != nil {
			c.removeElement(oldest)
		}
	}
}

// Len reports the number of cached entries.
func (c *Cache[K, V]) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.ll.Len()
}

func (c *Cache[K, V]) removeElement(el *list.Element) {
	e := el.Value.(*entry[K, V])
	delete(c.m, e.key)
	c.ll.Remove(el)
}
