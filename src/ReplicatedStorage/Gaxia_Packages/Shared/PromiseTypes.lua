--!strict
-- ─────────────────────────────────────────────────────────────
-- PromiseTypes.lua
-- Location: ReplicatedStorage/Gaxia_Packages/Shared/PromiseTypes
-- Purpose : TYPE-ONLY companion for the vendored evaera Promise (Shared/Promise,
--           left untouched: it is non-strict and exports no types). Annotate a
--           promise-returning API with these so callers get :andThen / :await /
--           :expect ... completion and typed await results.
--
-- Access  : types only — the module value is an empty table.
--   local PromiseTypes = require(ReplicatedStorage.Gaxia_Packages.Shared.PromiseTypes)
--   function M.Load(): PromiseTypes.Promise<Model> ... end
--   local ok, model = M.Load():await()        -- ok: boolean, model: Model
--
-- Why chaining methods return the non-generic AnyPromise: a generic type whose
-- methods return the same alias with DIFFERENT type arguments (andThen<U...> ->
-- Promise<U...>) is rejected by Luau's type checker as a recursive type used with
-- different parameters. So everything that can change the resolved values
-- (andThen / catch / finally / andThenCall / andThenReturn / finallyCall /
-- finallyReturn) returns AnyPromise; the value-preserving ones (tap / timeout /
-- now) keep Promise<T...>.
-- ─────────────────────────────────────────────────────────────

-- Promise.Status members (the enum values are these strings).
export type Status = "Started" | "Resolved" | "Rejected" | "Cancelled"

-- A promise whose resolved values are not tracked (every value is `any`).
export type AnyPromise = {
	-- Chain: runs successHandler with the resolved values (or failureHandler with
	-- the rejection); a returned Promise is chained onto.
	andThen: (
		self: AnyPromise,
		successHandler: ((...any) -> ...any)?,
		failureHandler: ((...any) -> ...any)?
	) -> AnyPromise,
	catch: (self: AnyPromise, failureHandler: (...any) -> ...any) -> AnyPromise,
	-- Like andThen, but passes the original values through.
	tap: (self: AnyPromise, tapHandler: (...any) -> ...any) -> AnyPromise,
	andThenCall: (self: AnyPromise, callback: (...any) -> ...any, ...any) -> AnyPromise,
	andThenReturn: (self: AnyPromise, ...any) -> AnyPromise,
	-- Runs whatever the fate (resolved, rejected or cancelled).
	finally: (self: AnyPromise, finallyHandler: (status: Status) -> ...any) -> AnyPromise,
	finallyCall: (self: AnyPromise, callback: (...any) -> ...any, ...any) -> AnyPromise,
	finallyReturn: (self: AnyPromise, ...any) -> AnyPromise,
	-- Rejects with rejectionValue (default: a TimedOut Promise.Error) after `seconds`.
	timeout: (self: AnyPromise, seconds: number, rejectionValue: any?) -> AnyPromise,
	-- Resolves now if already resolved, else rejects (default: NotResolvedInTime).
	now: (self: AnyPromise, rejectionValue: any?) -> AnyPromise,
	cancel: (self: AnyPromise) -> (),
	getStatus: (self: AnyPromise) -> Status,
	-- Yields. (true, values...) if resolved, else (false, rejection...).
	await: (self: AnyPromise) -> (boolean, ...any),
	-- Yields. (status, values...).
	awaitStatus: (self: AnyPromise) -> (Status, ...any),
	-- Yields. The resolved values; ERRORS if the promise rejects or is cancelled.
	expect: (self: AnyPromise) -> ...any,
	-- Deprecated alias of expect.
	awaitValue: (self: AnyPromise) -> ...any,
}

-- A promise that resolves with T... (await / expect / andThen's handler are typed).
export type Promise<T...> = {
	andThen: (
		self: Promise<T...>,
		successHandler: ((T...) -> ...any)?,
		failureHandler: ((...any) -> ...any)?
	) -> AnyPromise,
	catch: (self: Promise<T...>, failureHandler: (...any) -> ...any) -> AnyPromise,
	tap: (self: Promise<T...>, tapHandler: (T...) -> ...any) -> Promise<T...>,
	andThenCall: (self: Promise<T...>, callback: (...any) -> ...any, ...any) -> AnyPromise,
	andThenReturn: (self: Promise<T...>, ...any) -> AnyPromise,
	finally: (self: Promise<T...>, finallyHandler: (status: Status) -> ...any) -> AnyPromise,
	finallyCall: (self: Promise<T...>, callback: (...any) -> ...any, ...any) -> AnyPromise,
	finallyReturn: (self: Promise<T...>, ...any) -> AnyPromise,
	timeout: (self: Promise<T...>, seconds: number, rejectionValue: any?) -> Promise<T...>,
	now: (self: Promise<T...>, rejectionValue: any?) -> Promise<T...>,
	cancel: (self: Promise<T...>) -> (),
	getStatus: (self: Promise<T...>) -> Status,
	-- On rejection the values after `false` are the rejection values, not T...
	await: (self: Promise<T...>) -> (boolean, T...),
	awaitStatus: (self: Promise<T...>) -> (Status, T...),
	expect: (self: Promise<T...>) -> T...,
	awaitValue: (self: Promise<T...>) -> T...,
}

return {}
