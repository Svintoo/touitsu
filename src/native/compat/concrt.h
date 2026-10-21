// compat/concrt.h - minimal stand-in for MSVC's <concrt.h> (Concurrency Runtime),
// which doesn't exist in MinGW/clang. Only what Textractor needs; extend if the
// compiler reports more missing Concurrency:: names.
#pragma once
#include <mutex>
#include <shared_mutex>

namespace Concurrency
{
	// Non-reentrant mutex (MSVC's critical_section is also non-reentrant).
	class critical_section
	{
	public:
		class scoped_lock
		{
		public:
			explicit scoped_lock(critical_section& cs) : cs(cs) { cs.lock(); }
			~scoped_lock() { cs.unlock(); }
			scoped_lock(const scoped_lock&) = delete;
			scoped_lock& operator=(const scoped_lock&) = delete;
		private:
			critical_section& cs;
		};
		void lock() { m.lock(); }
		bool try_lock() { return m.try_lock(); }
		void unlock() { m.unlock(); }
	private:
		std::mutex m;
	};

	class reader_writer_lock
	{
	public:
		class scoped_lock
		{
		public:
			explicit scoped_lock(reader_writer_lock& l) : l(l) { l.m.lock(); }
			~scoped_lock() { l.m.unlock(); }
			scoped_lock(const scoped_lock&) = delete;
			scoped_lock& operator=(const scoped_lock&) = delete;
		private:
			reader_writer_lock& l;
		};
		class scoped_lock_read
		{
		public:
			explicit scoped_lock_read(reader_writer_lock& l) : l(l) { l.m.lock_shared(); }
			~scoped_lock_read() { l.m.unlock_shared(); }
			scoped_lock_read(const scoped_lock_read&) = delete;
			scoped_lock_read& operator=(const scoped_lock_read&) = delete;
		private:
			reader_writer_lock& l;
		};
		// Writer lock/unlock. (MSVC's unlock() can release either mode; this one assumes writer.
		// If Textractor calls lock_read()/unlock() manually, revisit.)
		void lock() { m.lock(); }
		void unlock() { m.unlock(); }
		void lock_read() { m.lock_shared(); }
	private:
		std::shared_mutex m;
	};
}

// MSVC accepts both spellings.
namespace concurrency = Concurrency;