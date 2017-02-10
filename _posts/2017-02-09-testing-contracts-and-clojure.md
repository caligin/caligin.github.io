---
title: Testing contracts & Clojure
---

# Testing contracts & Clojure

Coming from a background of mainly Java, I'm a big fan of interfaces. They're not just a language construct for decoupling, they carry the meaning of a contract between implementations and clients.
Interfaces provide compiler safety on expected types, but they lack the ability to provide behaviour safety. Behaviour expected by a contract is usually conveyed by method names and APIDocs. Tests on the behaviour are commonly found among the per-implementation test suites.

An idea that I had in mind for some time was to create a JUnit runner that would allow to write a test suite for an interface, then instantiating it against each implementation to test the conformity to the contract. I'm expecting to gain the following benefits:

- Write the test suite for the general behaviour only once
- Tests are written by interface's authors, who have context on the correct expectations for implementations
- Test suite become simple guidance for implementers
- Test suite provides live documentation for clients that is independent from any implementation of the contract

I'd like to share what I found to be a simplicity win at obtaining this tool using Clojure's `clojure.test`: it might be a very simplistic realization but I help that explaining it into the context of contracts will give you a new testing tool.

I was specifically working with a protocol which I reified in two different implementations but this is a valuable tool for any case in which, aiming for functional composability, we accept behaviour as a parameter and we have expectations on it.

In a `deftest` the body is composed by a sequence of `testing`, generally against a single object under test. Something like this:

``` clojure
(defn sum-reduce [numbers]
  (reduce + 0 numbers))

(deftest reduce-implementation-of-sum
  (testing "sum 1 and 1 yields 2"
    (is (= 2 (sum-reduce [1 1]))))
  (testing "sum nothing yields 0"
    (is (= 0 (sum-reduce []))))
  (testing "sum 1, 1 and 2 yields 4"
    (is (= 4 (sum-reduce [1 1 2])))))
```

These tests all speak about the common theme of sum behaviour in the context of the `sum-reduce` implementation, let's make it obvious:

``` clojure
(defn sum-reduce [numbers]
  (reduce + 0 numbers))

(deftest reduce-implementation-of-sum
  (let [sum-fn-under-test sum-reduce]
    (testing "sum 1 and 1 yields 2"
      (is (= 2 (sum-fn-under-test [1 1]))))
    (testing "sum nothing yields 0"
      (is (= 0 (sum-fn-under-test []))))
    (testing "sum 1, 1 and 2 yields 4"
      (is (= 4 (sum-fn-under-test [1 1 2]))))))
```

Now, let's introduce a recursive implementation and the relative tests:

``` clojure
(defn sum-reduce [numbers]
  (reduce + 0 numbers))

(defn sum-recur [numbers]
  (loop [acc 0 [n & others] numbers]
    (cond
      (nil? n) acc
      :else (recur (+ acc n) others))))

(deftest reduce-implementation-of-sum
  (let [sum-fn-under-test sum-reduce]
    (testing "sum 1 and 1 yields 2"
      (is (= 2 (sum-fn-under-test [1 1]))))
    (testing "sum nothing yields 0"
      (is (= 0 (sum-fn-under-test []))))
    (testing "sum 1, 1 and 2 yields 4"
      (is (= 4 (sum-fn-under-test [1 1 2]))))))

(deftest recur-implementation-of-sum
  (let [sum-fn-under-test sum-recur]
    (testing "sum 1 and 1 yields 2"
      (is (= 2 (sum-fn-under-test [1 1]))))
    (testing "sum nothing yields 0"
      (is (= 0 (sum-fn-under-test []))))
    (testing "sum 1, 1 and 2 yields 4"
      (is (= 4 (sum-fn-under-test [1 1 2]))))))
```

Not only the two test suites look like duplication, they actually are as they carry the same meaning and would change for the same reason. So the idea here is to define a generic test suite for sum behaviour that can be instantiated against a specific implementation: moving the `let`s to be a `defn` accepting the function under test as a parameter fits the bill perfectly:

``` clojure
(defn sum-reduce [numbers]
  (reduce + 0 numbers))

(defn sum-recur [numbers]
  (loop [acc 0 [n & others] numbers]
    (cond
      (nil? n) acc
      :else (recur (+ acc n) others))))

(defn behaviour-of-sum-for [sum-fn-under-test]
  (testing "sum 1 and 1 yields 2"
    (is (= 2 (sum-fn-under-test [1 1]))))
  (testing "sum nothing yields 0"
    (is (= 0 (sum-fn-under-test []))))
  (testing "sum 1, 1 and 2 yields 4"
    (is (= 4 (sum-fn-under-test [1 1 2])))))

(deftest reduce-implementation-of-sum
  (behaviour-of-sum-for sum-reduce))

(deftest recur-implementation-of-sum
  (behaviour-of-sum-for sum-recur))
```

The `deftest`s now become a mere declaration that we want to check the behavioural conformity suite against either `sum-reduce` or `sum-recur`. This would enable authors of reusable code by means of high-order functions or polymorphism to convey their expectations to clients as an executable tool.

I hope that you find this little trick as useful as I do, personally I'll try to use it as often as I can.
