#! /usr/sbin/dtrace -C -s

/* Copyright (c) 2009-2010 Apple Inc. All rights reserved. */

/* Trace SMB server operations.
 *
 * The first column of output is the client file descriptor, so that when the
 * server is busy, you can always associate a single client operation stream.
 * If we saw the client connection operation, we will have the peer address
 * string and will add that to the send/receive operation messages. Note that
 * the send does not always get printed in the expected sequence. Maybe there
 * is some buffering affecting this.
 */

#pragma D option quiet

#define INDENT(fd, count) printf("%4.4u %*s", (fd), (count) * 4, " ")
#define OPCODE(opnum) (opcodes[opnum] == 0 ? "unknown" : opcodes[opnum])

string opcodes[int];
string clients[int];

inline int NSEC_PER_USEC = 1000; /* Convert nsec to usec */

BEGIN
{
    opcodes[0x00] = "SMB_COM_CREATE_DIRECTORY";
    opcodes[0x01] = "SMB_COM_DELETE_DIRECTORY";
    opcodes[0x02] = "SMB_COM_OPEN";
    opcodes[0x03] = "SMB_COM_CREATE";
    opcodes[0x04] = "SMB_COM_CLOSE";
    opcodes[0x05] = "SMB_COM_FLUSH";
    opcodes[0x06] = "SMB_COM_DELETE";
    opcodes[0x07] = "SMB_COM_RENAME";
    opcodes[0x08] = "SMB_COM_QUERY_INFORMATION";
    opcodes[0x09] = "SMB_COM_SET_INFORMATION";
    opcodes[0x0A] = "SMB_COM_READ";
    opcodes[0x0B] = "SMB_COM_WRITE";
    opcodes[0x0C] = "SMB_COM_LOCK_BYTE_RANGE";
    opcodes[0x0D] = "SMB_COM_UNLOCK_BYTE_RANGE";
    opcodes[0x0E] = "SMB_COM_CREATE_TEMPORARY";
    opcodes[0x0F] = "SMB_COM_CREATE_NEW";
    opcodes[0x10] = "SMB_COM_CHECK_DIRECTORY";
    opcodes[0x11] = "SMB_COM_PROCESS_EXIT";
    opcodes[0x12] = "SMB_COM_SEEK";
    opcodes[0x13] = "SMB_COM_LOCK_AND_READ";
    opcodes[0x14] = "SMB_COM_WRITE_AND_UNLOCK";
    opcodes[0x1A] = "SMB_COM_READ_RAW";
    opcodes[0x1B] = "SMB_COM_READ_MPX";
    opcodes[0x1C] = "SMB_COM_READ_MPX_SECONDARY";
    opcodes[0x1D] = "SMB_COM_WRITE_RAW";
    opcodes[0x1E] = "SMB_COM_WRITE_MPX";
    opcodes[0x20] = "SMB_COM_WRITE_COMPLETE";
    opcodes[0x22] = "SMB_COM_SET_INFORMATION2";
    opcodes[0x23] = "SMB_COM_QUERY_INFORMATION2";
    opcodes[0x24] = "SMB_COM_LOCKING_ANDX";
    opcodes[0x25] = "SMB_COM_TRANSACTION";
    opcodes[0x26] = "SMB_COM_TRANSACTION_SECONDARY";
    opcodes[0x27] = "SMB_COM_IOCTL";
    opcodes[0x28] = "SMB_COM_IOCTL_SECONDARY";
    opcodes[0x29] = "SMB_COM_COPY";
    opcodes[0x2A] = "SMB_COM_MOVE";
    opcodes[0x2B] = "SMB_COM_ECHO";
    opcodes[0x2C] = "SMB_COM_WRITE_AND_CLOSE";
    opcodes[0x2D] = "SMB_COM_OPEN_ANDX";
    opcodes[0x2E] = "SMB_COM_READ_ANDX";
    opcodes[0x2F] = "SMB_COM_WRITE_ANDX";
    opcodes[0x31] = "SMB_COM_CLOSE_AND_TREE_DISC";
    opcodes[0x32] = "SMB_COM_TRANSACTION2";
    opcodes[0x33] = "SMB_COM_TRANSACTION2_SECONDARY";
    opcodes[0x34] = "SMB_COM_FIND_CLOSE2";
    opcodes[0x35] = "SMB_COM_FIND_NOTIFY_CLOSE";
    opcodes[0x70] = "SMB_COM_TREE_CONNECT";
    opcodes[0x71] = "SMB_COM_TREE_DISCONNECT";
    opcodes[0x72] = "SMB_COM_NEGOTIATE";
    opcodes[0x73] = "SMB_COM_SESSION_SETUP_ANDX";
    opcodes[0x74] = "SMB_COM_LOGOFF_ANDX";
    opcodes[0x75] = "SMB_COM_TREE_CONNECT_ANDX";
    opcodes[0x80] = "SMB_COM_QUERY_INFORMATION_DISK";
    opcodes[0x81] = "SMB_COM_SEARCH";
    opcodes[0x82] = "SMB_COM_FIND";
    opcodes[0x83] = "SMB_COM_FIND_UNIQUE";
    opcodes[0xA0] = "SMB_COM_NT_TRANSACT";
    opcodes[0xA1] = "SMB_COM_NT_TRANSACT_SECONDARY";
    opcodes[0xA2] = "SMB_COM_NT_CREATE_ANDX";
    opcodes[0xA4] = "SMB_COM_NT_CANCEL";
    opcodes[0xA5] = "SMB_COM_NT_RENAME";
    opcodes[0xC0] = "SMB_COM_OPEN_PRINT_FILE";
    opcodes[0xC1] = "SMB_COM_WRITE_PRINT_FILE";
    opcodes[0xC2] = "SMB_COM_CLOSE_PRINT_FILE";
    opcodes[0xC3] = "SMB_COM_GET_PRINT_QUEUE";
}

smbd*:::transport-connect
{
    clients[arg0] = copyinstr(arg1);
    printf("%4.4u %s connected\n", arg0, copyinstr(arg1));
}

smbd*:::transport-disconnect
{
    printf("%4.4u %s disconnected\n", arg0, clients[arg0]);
    clients[arg0] = 0;
}

smbd*:::transport-nbtreceive
{
    peername = clients[arg0];
    printf("%4.4u received %u bytes%s%s\n", arg0, arg1,
            peername != "" ? " from " : "",
            peername != "" ? peername : "");
}

smbd*:::transport-nbtsend
{
    peername = clients[arg0];
    printf("%4.4u sent %u bytes%s%s\n", arg0, arg1,
            peername != "" ? " to " : "",
            peername != "" ? peername : "");
}

smbd*:::smb1-dispatch-begin
{
    self->depth = 0;
    self->fd = arg0;
    self->trace = 1;
    self->dispatch = timestamp;
    printf("%4.4u %s(0x%X)\n", arg0, OPCODE(arg1), arg1);
}

smbd*:::smb1-dispatch-end
{
    elapsed = timestamp - self->dispatch;
    printf("%4.4u %s status 0x%08X (%u usec)\n",
            arg0, OPCODE(arg1), arg2, elapsed / NSEC_PER_USEC);

    self->depth = 0;
    self->trace = 0;
    self->dispatch = 0;
}

ntvfs*:::*-entry
{
    self->depth++;
    INDENT(self->fd, self->depth);
    printf("ntvfs::%s\n", probename);
}

ntvfs*:::*-return
{
    INDENT(self->fd, self->depth);
    printf("ntvfs::%s status 0x%08X\n", probename, arg0);

    self->depth--;
}

syscall:::entry
/ self->trace /
{
    self->syscall = timestamp
}

syscall:::return
/ self->trace /
{
    elapsed = timestamp - self->syscall;

    INDENT(self->fd, self->depth + 1);
    printf("%s -> %d (errno %u) (%u usec)\n", probefunc, arg0,
            errno, elapsed / NSEC_PER_USEC);

    self->syscall = 0;
}

/* vim: set ts=4 sw=4 tw=79 et cindent : */
