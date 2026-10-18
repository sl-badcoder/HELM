#include <stdlib.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <assert.h>
#include "hpcs_types.h"

#define CAPACITY 1000000
#define likely(x)      __builtin_expect(!!(x), 1) 
#define unlikely(x)    __builtin_expect(!!(x), 0) 

static volatile sig_atomic_t cont = 1;

void sighandler(int signum, siginfo_t* info, void* ptr)
{
    (void)signum;
    (void)info;
    (void)ptr;
    cont = 0;
}

static void write_all(int fd, const void *buffer, size_t length)
{
    const unsigned char *cursor = buffer;

    while (length > 0) {
        ssize_t written = write(fd, cursor, length);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            perror("write failed");
            exit(EXIT_FAILURE);
        }
        if (written == 0) {
            fprintf(stderr, "write returned zero before the buffer was flushed\n");
            exit(EXIT_FAILURE);
        }
        cursor += written;
        length -= written;
    }
}

unsigned char write_magic_byte(int ofd) 
{
    int fd;                // File descriptor for the input file
    unsigned int value;    // Variable to store the unsigned int read from the file
    ssize_t bytes_read;
    char buffer[16];       // Buffer to read the integer in textual form

    // Open the input file for reading
    fd = open("/sys/module/nvidia_uvm/parameters/hpcs_log_short", O_RDONLY);
    if (fd == -1) {
        perror("Error opening file");
        exit(EXIT_FAILURE);
    }

    // Read the value as a string from the file
    bytes_read = read(fd, buffer, sizeof(buffer) - 1);
    if (bytes_read == -1) {
        perror("Error reading from file");
        close(fd);
        exit(EXIT_FAILURE);
    }

    buffer[bytes_read] = '\0';  // Null-terminate the string

    // Convert string to unsigned integer
    value = atoi(buffer);

    // Check if the value is within the range of an unsigned char
    if (value > 255) {
        fprintf(stderr, "Value out of range for a single byte\n");
        close(fd);
        exit(EXIT_FAILURE);
    }
    unsigned char byte_value = (unsigned char)value;  // Cast to unsigned char
    // Write the byte to the output file descriptor
    write_all(ofd, &byte_value, sizeof(byte_value));

    // Close the input file descriptor
    close(fd);
    return byte_value;
}


void write_hostname(int ofd) {
    char hostname[256];
    if (gethostname(hostname, sizeof(hostname)) == -1) 
    {
        perror("gethostname failed");
        exit(-1);
    }

    unsigned char len = strlen(hostname);
    write_all(ofd, &len, sizeof(len));
    write_all(ofd, hostname, len);
}


void log_short(int fd, int ofd)
{
    int ret = 0;
    struct hpcs_fault_record_short* dat = malloc(sizeof(struct hpcs_fault_record_short) * CAPACITY);
    struct hpcs_fault_record_short* next = NULL;
    if (!dat)
    {
        fprintf(stderr, "Failed to allocate %lu bytes, exiting.\n", sizeof(struct hpcs_fault_record_short) * CAPACITY);
        exit(1);
    }
    next = dat;

    while(cont)
    {
        ret = read(fd, next, CAPACITY - (next - dat));
        if (likely(ret > 0))
        {
            /*
               for (int i = 0; i < ret; ++i)
               {
               printf("Read This Address from Kernel: %lx, reset byte %lx \n", next[i].faddr, next[i].faddr & 0x00FFFFFFFFFFFFFF);
               }
               */
            next += ret;
            // if local buffer is over 90% full let's write out the data
            if (unlikely((size_t)(next - dat) >= (size_t)(CAPACITY * .9)))
            {
                write_all(ofd, dat, (size_t)(next - dat) * sizeof(*dat));
                next = dat;
            }
        }
        else if (ret == 0)
        {
            if (next != dat)
            {
                write_all(ofd, dat, (size_t)(next - dat) * sizeof(*dat));
                next = dat;
            }
        }
        else if (errno != EINTR)
        {
            perror("Failed to read hpcs_logger");
            free(dat);
            exit(EXIT_FAILURE);
        }
    }
    if (next != dat)
        write_all(ofd, dat, (size_t)(next - dat) * sizeof(*dat));
    free(dat);
}

void log_long(int fd, int ofd)
{
    int ret = 0;
    struct hpcs_fault_record* dat = malloc(sizeof(struct hpcs_fault_record) * CAPACITY);
    struct hpcs_fault_record* next = NULL;
    if (!dat)
    {
        fprintf(stderr, "Failed to allocate %lu bytes, exiting.\n", sizeof(struct hpcs_fault_record) * CAPACITY);
        exit(1);
    }
    next = dat;

    while(cont)
    {
        ret = read(fd, next, CAPACITY - (next - dat));
        if (likely(ret > 0))
        {
            next += ret;
            // if local buffer is over 90% full let's write out the data
            if (unlikely((size_t)(next - dat) >= (size_t)(CAPACITY * .9)))
            {
                write_all(ofd, dat, (size_t)(next - dat) * sizeof(*dat));
                next = dat;
            }
        }
        else if (ret == 0)
        {
            if (next != dat)
            {
                write_all(ofd, dat, (size_t)(next - dat) * sizeof(*dat));
                next = dat;
            }
        }
        else if (errno != EINTR)
        {
            perror("Failed to read hpcs_logger");
            free(dat);
            exit(EXIT_FAILURE);
        }
    }
    if (next != dat)
        write_all(ofd, dat, (size_t)(next - dat) * sizeof(*dat));
    free(dat);
}

int main(int argc, char* argv[]) {
    int fd, ofd;
    unsigned char hpcs_log_short;
    struct sigaction sig = {0};
    if (argc != 2) 
    { 
        fprintf(stderr, "usage: %s <output_file_name>\n", argv[0]); 
        return EXIT_FAILURE;
    }

    // Open the device file
    fd = open("/dev/hpcs_logger", O_RDONLY);
    mode_t permissions = S_IRWXU | S_IRGRP | S_IXGRP | S_IROTH | S_IXOTH;
    ofd = open(argv[1], O_WRONLY | O_CREAT | O_TRUNC, permissions);
    if (fd < 0) {
        perror("Failed to open the device");
        exit(1);
    }
    if (ofd < 0)
    {
        fprintf (stderr, "Failed to open output file %s\n", argv[1]);
        exit(1);
    }

    sig.sa_sigaction = sighandler;
    sig.sa_flags = SA_SIGINFO;
    sigaction(SIGTERM, &sig, NULL);
    sigaction(SIGINT, &sig, NULL);

    fprintf(stderr, "log init finished\n");

    hpcs_log_short = write_magic_byte(ofd);
    write_hostname(ofd);
    printf("Starting logger in mode %u based on magic byte\n", hpcs_log_short); 
    if(hpcs_log_short)
    {
        log_short(fd, ofd);
    }
    else
    {
        log_long(fd, ofd);
    }


    // Close the device file
    fsync(ofd);
    close(fd);
    close(ofd);
    return EXIT_SUCCESS;
}
