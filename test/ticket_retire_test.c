/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <stdio.h>
#include "../src/bg_ticket_retire.h"

struct test { unsigned seals, aborts, waits; int seal_fail, wait_fail, abort_fail; };
static int end(void *p, uint64_t generation, uint64_t epoch, int abort, uint32_t seq) {
   struct test *t=p;
   assert(generation >= 1 && generation <= 3 && epoch == 7);
   if (abort) {
      assert(t->waits && !t->wait_fail && seq == 0);
      ++t->aborts;
      return t->abort_fail;
   }
   assert(seq == 42 && !t->waits);
   ++t->seals;
   return t->seal_fail && generation != 2;
}
static int wait(void *p) { struct test *t=p; ++t->waits; return t->wait_fail; }
static void run(struct test *t, uint32_t seq, int result, unsigned left) {
   uint64_t gen[]={1,2,3}, epoch[]={7,7,7}; unsigned count=3;
   assert(bg_ticket_retire(gen,epoch,&count,seq,t,end,wait)==result);
   assert(count==left);
   if (left==2) assert(gen[0]==1 && gen[1]==3 && epoch[0]==7 && epoch[1]==7);
}
int main(void) {
   struct test success={0}; run(&success,42,0,0);
   assert(success.seals==3 && !success.waits && !success.aborts);
   struct test cancelled={.seal_fail=1}; run(&cancelled,42,-1,0);
   assert(cancelled.seals==3 && cancelled.waits==1 && cancelled.aborts==2);
   struct test timeout={.seal_fail=1,.wait_fail=1}; run(&timeout,42,-1,2);
   assert(timeout.waits==1 && !timeout.aborts);
   struct test abort_error={.seal_fail=1,.abort_fail=1}; run(&abort_error,42,-1,2);
   assert(abort_error.waits==1 && abort_error.aborts==2);
   struct test empty={0}; run(&empty,0,0,0);
   assert(!empty.seals && empty.waits==1 && empty.aborts==3);
   struct test no_proof={.wait_fail=1}; run(&no_proof,0,-1,3);
   assert(!no_proof.seals && no_proof.waits==1 && !no_proof.aborts);
   puts("PASS: seal, cancelled drain/abort, failed wait retains ownership, failed abort, missing seqno");
}
