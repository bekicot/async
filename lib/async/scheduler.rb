# Copyright, 2020, by Samuel G. D. Williams. <http://www.codeotaku.com>
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.

require_relative 'clock'
require_relative 'task'

require 'io/event'

require 'console'
require 'timers'
require 'resolv'

module Async
	# Handles scheduling of fibers. Implements the fiber scheduler interface.
	class Scheduler < Node
		# Whether the fiber scheduler is supported.
		# @public Since `stable-v1`.
		def self.supported?
			true
		end
		
		def initialize(parent = nil, selector: nil)
			super(parent)
			
			@selector = selector || ::IO::Event::Selector.new(Fiber.current)
			@interrupted = false
			
			@blocked = 0
			
			@timers = ::Timers::Group.new
		end
		
		# @public Since `stable-v1`.
		def close
			# This is a critical step. Because tasks could be stored as instance variables, and since the reactor is (probably) going out of scope, we need to ensure they are stopped. Otherwise, the tasks will belong to a reactor that will never run again and are not stopped.
			self.terminate
			
			Kernel::raise "Closing scheduler with blocked operations!" if @blocked > 0
			
			# We depend on GVL for consistency:
			# @guard.synchronize do
			
			@selector&.close
			@selector = nil
			
			# end
			
			consume
		end
		
		# @returns [Boolean] Whether the scheduler has been closed.
		# @public Since `stable-v1`.
		def closed?
			@selector.nil?
		end
		
		def to_s
			"\#<#{self.description} #{@children&.size || 0} children (#{stopped? ? 'stopped' : 'running'})>"
		end
		
		# Interrupt the event loop and cause it to exit.
		def interrupt
			@interrupted = true
			@selector.wakeup
		end
		
		# Transfer from the calling fiber to the event loop.
		def transfer
			@selector.transfer
		end
		
		# Yield the current fiber and resume it on the next iteration of the event loop.
		def yield
			@selector.yield
		end
		
		# Schedule a fiber (or equivalent object) to be resumed on the next loop through the reactor.
		# @parameter fiber [Fiber | Object] The object to be resumed on the next iteration of the run-loop.
		def push(fiber)
			@selector.push(fiber)
		end
		
		def raise(*arguments)
			@selector.raise(*arguments)
		end
		
		def resume(fiber, *arguments)
			if Fiber.scheduler
				@selector.resume(fiber, *arguments)
			else
				@selector.push(fiber)
			end
		end
		
		# Invoked when a fiber tries to perform a blocking operation which cannot continue. A corresponding call {unblock} must be performed to allow this fiber to continue.
		# @asynchronous May only be called on same thread as fiber scheduler.
		def block(blocker, timeout)
			# $stderr.puts "block(#{blocker}, #{Fiber.current}, #{timeout})"
			fiber = Fiber.current
			
			if timeout
				timer = @timers.after(timeout) do
					if fiber.alive?
						fiber.transfer(false)
					end
				end
			end
			
			begin
				@blocked += 1
				@selector.transfer
			ensure
				@blocked -= 1
			end
		ensure
			timer&.cancel
		end
		
		# @asynchronous May be called from any thread.
		def unblock(blocker, fiber)
			# $stderr.puts "unblock(#{blocker}, #{fiber})"
			
			# This operation is protected by the GVL:
			@selector.push(fiber)
			@selector.wakeup
		end
		
		# @asynchronous May be non-blocking..
		def kernel_sleep(duration = nil)
			if duration
				self.block(nil, duration)
			else
				self.transfer
			end
		end
		
		# @asynchronous May be non-blocking..
		def address_resolve(hostname)
			::Resolv.getaddresses(hostname)
		end
		
		# @asynchronous May be non-blocking..
		def io_wait(io, events, timeout = nil)
			fiber = Fiber.current
			
			if timeout
				timer = @timers.after(timeout) do
					fiber.raise(TimeoutError)
				end
			end
			
			# Console.logger.info(self, "-> io_wait", fiber, io, events)
			events = @selector.io_wait(fiber, io, events)
			# Console.logger.info(self, "<- io_wait", fiber, io, events)
			
			return events
		rescue TimeoutError
			return false
		ensure
			timer&.cancel
		end

		if IO.const_defined?(:Buffer)
			def io_read(io, buffer, length)
				@selector.io_read(Fiber.current, io, buffer, length)
			end
			
			def io_write(io, buffer, length)
				@selector.io_write(Fiber.current, io, buffer, length)
			end
		end
		
		# Wait for the specified process ID to exit.
		# @parameter pid [Integer] The process ID to wait for.
		# @parameter flags [Integer] A bit-mask of flags suitable for `Process::Status.wait`.
		# @returns [Process::Status] A process status instance.
		# @asynchronous May be non-blocking..
		def process_wait(pid, flags)
			return @selector.process_wait(Fiber.current, pid, flags)
		end
		
		# Run one iteration of the event loop.
		# @parameter timeout [Float | Nil] The maximum timeout, or if nil, indefinite.
		# @returns [Boolean] Whether there is more work to do.
		def run_once(timeout = nil)
			Kernel::raise "Running scheduler on non-blocking fiber!" unless Fiber.blocking?
			
			# If we are finished, we stop the task tree and exit:
			if self.finished?
				return false
			end
			
			interval = @timers.wait_interval
			
			# If there is no interval to wait (thus no timers), and no tasks, we could be done:
			if interval.nil?
				# Allow the user to specify a maximum interval if we would otherwise be sleeping indefinitely:
				interval = timeout
			elsif interval < 0
				# We have timers ready to fire, don't sleep in the selctor:
				interval = 0
			elsif timeout and interval > timeout
				interval = timeout
			end
			
			begin
				@selector.select(interval)
			rescue Errno::EINTR
				# Ignore.
			end
			
			@timers.fire
			
			# The reactor still has work to do:
			return true
		end
		
		# Run the reactor until all tasks are finished. Proxies arguments to {#async} immediately before entering the loop, if a block is provided.
		def run(...)
			Kernel::raise RuntimeError, 'Reactor has been closed' if @selector.nil?
			
			initial_task = self.async(...) if block_given?
			
			@interrupted = false
			
			while self.run_once
				if @interrupted
					break
				end
			end
			
			return initial_task
		ensure
			Console.logger.debug(self) {"Exiting run-loop because #{$! ? $! : 'finished'}."}
		end
		
		# Start an asynchronous task within the specified reactor. The task will be
		# executed until the first blocking call, at which point it will yield and
		# and this method will return.
		#
		# This is the main entry point for scheduling asynchronus tasks.
		#
		# @yields {|task| ...} Executed within the task.
		# @returns [Task] The task that was scheduled into the reactor.
		# @deprecated With no replacement.
		def async(*arguments, **options, &block)
			task = Task.new(Task.current? || self, **options, &block)
			
			# I want to take a moment to explain the logic of this.
			# When calling an async block, we deterministically execute it until the
			# first blocking operation. We don't *have* to do this - we could schedule
			# it for later execution, but it's useful to:
			# - Fail at the point of the method call where possible.
			# - Execute determinstically where possible.
			# - Avoid scheduler overhead if no blocking operation is performed.
			task.run(*arguments)
			
			# Console.logger.debug "Initial execution of task #{fiber} complete (#{result} -> #{fiber.alive?})..."
			return task
		end
		
		def fiber(...)
			return async(...).fiber
		end
		
		# Invoke the block, but after the specified timeout, raise {TimeoutError} in any currenly blocking operation. If the block runs to completion before the timeout occurs or there are no non-blocking operations after the timeout expires, the code will complete without any exception.
		# @parameter duration [Numeric] The time in seconds, in which the task should complete.
		def timeout_after(timeout, exception = TimeoutError, message = "execution expired", &block)
			fiber = Fiber.current
			
			timer = @timers.after(timeout) do
				if fiber.alive?
					fiber.raise(exception, message)
				end
			end
			
			yield timer
		ensure
			timer.cancel if timer
		end
	end
end
