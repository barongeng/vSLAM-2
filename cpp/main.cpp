
#include <ros/ros.h>

#include <image_transport/image_transport.h>
#include <sensor_msgs/image_encodings.h>
#include <tf/transform_listener.h>
#include <cv_bridge/cv_bridge.h>

#include <opencv2/highgui/highgui.hpp>
#include <opencv2/features2d/features2d.hpp>

#include <pthread.h> // compared to Boost, this is frickin' lightweight!! :D
#include <unistd.h> // execl
#include <signal.h> // kill, SIGTERM
// #include <stdio.h>
#include <wordexp.h> // strtok (fused args splitting)

#include "main.h"
#include "non-maxima-suppression.h"
#include "visualize.h"
#include "keypoints.h"
#include "tf.h"

using namespace cv;
using namespace std;

pthread_mutex_t frame_mutex;
pthread_cond_t cond_consumer, cond_producer;

Frame *frame, *persistent_frame;

int killed = 0;

class RosMain
{
	/// Private variables
	ros::NodeHandle nh_;
	image_transport::ImageTransport it_;
	image_transport::Subscriber image_sub_;
	//image_transport::Publisher image_pub_;
	cv::Mat mask;
	tf::TransformListener tf_listener;
	
	FILE *log;
	
	/// Detect the keypoints in an image.
	// This routine (optionally) splits the image processing into cells.
	// If it is not done this way, only features from one direction
	// may be generated.
	// uses the 'mask' private class variable
	void detect_keypoints(Mat image, vector<KeyPoint> *keypoints, Mat *descriptors, int *count)
	{
		int h_cells = 3, v_cells = 1;
		int w = image.cols, h=image.rows;
		int margin = 31;
		ORB *orb = new ORB(1000 / h_cells / v_cells);
		for (int j = 0; j < v_cells; j++) {
			for (int i = 0; i < h_cells; i++) {
				std::vector<KeyPoint> cell_keypoints;
				Mat cell_descriptors;
				int x = w/h_cells*i, y = h/v_cells*j;
				int lmargin = min(margin,x), tmargin = min(margin,y);
				int rmargin = min(margin, w-x-w/h_cells), bmargin = min(margin, h-y-h/v_cells);
				
				Rect cell(x - lmargin, y - tmargin, w/h_cells + lmargin + rmargin, h/v_cells + tmargin + bmargin);
				(*orb)(image(cell), mask(cell), cell_keypoints, cell_descriptors);
				
				for (int k = 0; k < cell_keypoints.size(); k++) {
					cell_keypoints[k].pt.x += x-lmargin;
					cell_keypoints[k].pt.y += y-tmargin;
				}
				
				descriptors->push_back(cell_descriptors);
				keypoints->insert(keypoints->end(), cell_keypoints.begin(), cell_keypoints.end());
			}
		}
		*count = descriptors->rows;
	}
	
public:
	RosMain() : it_(nh_)
	{
		// Subscrive to input video feed and publish output video feed
		image_sub_ = it_.subscribe("/viz/pano_vodom/image", 1, &RosMain::imageCb, this);
		//image_pub_ = it_.advertise("/image_converter/output_video", 1);
		

		cv::Mat mask0 = cv::imread("../res/panomask4.png"); // TODO: garbage collection?
		cv::cvtColor(mask0, mask, CV_RGB2GRAY);

		cv::namedWindow("Keypoints");
		
		log = fopen("/home/pavel/log.txt", "w");
	}

	~RosMain()
	{
		cv::destroyWindow("Keypoints");
		fclose(log);
	}

	// features producer
	void imageCb(const sensor_msgs::ImageConstPtr& msg)
	{
		ROS_INFO("Acquired an image.");
		static int frame_id = 1;
		cv_bridge::CvImagePtr cv_ptr;
		try {
			cv_ptr = cv_bridge::toCvCopy(msg, sensor_msgs::image_encodings::BGR8);
		}
		catch (cv_bridge::Exception& e) {
			ROS_ERROR("cv_bridge exception: %s", e.what());
			return;
		}
		
		static ros::Time last_t = cv_ptr->header.stamp;
		ros::Time now_t = cv_ptr->header.stamp;
		
		// Relative transformation from robot kinematics is acquired here.
		tf::StampedTransform transform;
		try {
			cout << "time interval: [" << last_t << ", " << now_t << "]\n";
			// This line is by Vladimir Kubelka, blame him! :D
			tf_listener.lookupTransform("/omnicam", last_t, "/omnicam", now_t, "/odom", transform);
			double *mat = (double*)malloc(sizeof(double) * 16);
			transform.getOpenGLMatrix(mat);
			to_my_coords(mat);
			fprintf(log, "[[%f, %f, %f, %f],", mat[0], mat[4], mat[8], mat[12]);
			fprintf(log, "[%f, %f, %f, %f],", mat[1], mat[5], mat[9], mat[13]);
			fprintf(log, "[%f, %f, %f, %f],", mat[2], mat[6], mat[10], mat[14]);
			fprintf(log, "[%f, %f, %f, %f]]\n", mat[3], mat[7], mat[11], mat[15]);
			free(mat);
		} catch (tf::TransformException ex){
			ROS_ERROR("TF error: %s",ex.what());
		}
		

		pthread_mutex_lock(&frame_mutex);	// protect buffer
		{
			free_keypoints(frame->num_kps, frame->kps);

			ROS_INFO("Computing ORB features...");

			// Create some features
			vector<KeyPoint> keypoints;
			Mat descriptors;
			detect_keypoints(cv_ptr->image, &keypoints, &descriptors, &(frame->num_kps));
			
			frame->id = frame_id;
			frame->dt = (now_t - last_t).toSec();
			frame->kps = keypoints_to_structs(keypoints, descriptors, cv_ptr->image.cols, cv_ptr->image.rows);

			ROS_INFO("Non-maxima suppression...");
	
			non_maxima_suppression(&(frame->kps), &(frame->num_kps), frame_id);

			printf("nfeatures: %d\n", frame->num_kps);
			
			// Produced another value successfully!
			pthread_cond_signal(&cond_consumer);
		}
		pthread_mutex_unlock(&frame_mutex);	// release the buffer
		
		ROS_INFO("Drawing the output image...");
		
		draw_image(cv_ptr->image, frame->kps, frame->num_kps, frame_id);
		cv::waitKey(3);

		frame_id++;
		last_t = now_t;
	}
};


// *features consumer
// waits for the next image if it was called too quickly; takes the current 
// image, if called too late.
Frame *extract_keypoints()
{	
	if (killed) {
		printf("extract_keypoints detected the ROS thread was killed.\n");
	}
	
	Frame *ret = (Frame *)malloc(sizeof(Frame));
	// save features to the global structure
	pthread_mutex_lock(&frame_mutex);	// protect buffer
	{
		printf("waiting for the producer of keypoints to produce something...\n");
		pthread_cond_wait(&cond_consumer, &frame_mutex);
		
		Keypoint *features = frame->kps;
		int nfeatures = frame->num_kps;

		if (persistent_frame) {
			free_keypoints(persistent_frame->num_kps, persistent_frame->kps);
			free(persistent_frame);
		}
		
		memcpy(ret, frame, sizeof(Frame));
		ret->kps = (Keypoint *)malloc(sizeof(Keypoint)*nfeatures);
		memcpy(ret->kps, features, sizeof(Keypoint)*nfeatures);
		for (int i = 0; i < nfeatures; i++) {
			char *descriptor = (char *)malloc(features[i].descriptor_size);
			memcpy(descriptor, features[i].descriptor, features[i].descriptor_size);
			ret->kps[i].descriptor = descriptor;
		}
		ret->num_kps = nfeatures;
		persistent_frame = ret;
	}
	pthread_mutex_unlock(&frame_mutex);	// release the buffer
	
	return ret;
}

int argc = 0;
char **argv;

static void *ros_init (void *arg)
{		
	// ROS loop init
	ros::init(argc, argv, "fastSLAM_2");
	RosMain ic;

	printf("Starting the main ROS loop...\n");
	ros::spin();
	printf("Exitted the main ROS loop.\n");
	killed = 1;
	return 0;
}

int main_c(char *args) {
	frame = (Frame *)malloc(sizeof(Frame));
	// Arguments parsing
	char *delimiter = ";";
	argv = (char **)malloc((strlen(args)/2 + 1) * sizeof(char*));
	argv[0] = strtok (args, delimiter);
	while (argv[++argc] = strtok (0, delimiter)) { }
	
	// Spawning the main loop
	pthread_t ros_loop_thread;
	int rc = pthread_create(&ros_loop_thread, NULL, ros_init, NULL);
    if (rc) {
         printf("ERROR: return code from pthread_create() is %d\n", rc);
         exit(-1);
    }
	printf("main is finishing\n");
	return 0;
}
